
#!/usr/bin/env swift
import Foundation
import EventKit

#Can give access to one or more calendars
let calendarName = "Family"
let senderEmail = "sender@example.com"
let recipientEmail = "recipient@example.com"   
let smtpHost = "your SMTP host"
let smtpPort = your port
let smtpUsername = "your username"
let keychainService = "family-calendar-sync-smtp"

#I’ve set the lookup to 9 months
let lookaheadMonths = 9
let baseSendDelaySeconds: UInt32 = 3
let retryDelaysSeconds: [UInt32] = [5, 15, 30]

let home = FileManager.default.homeDirectoryForCurrentUser
let appDir = home.appendingPathComponent("Library").appendingPathComponent("Application Support").appendingPathComponent("family_calendar_sync")
let stateURL = appDir.appendingPathComponent("state.json")
let logURL = appDir.appendingPathComponent("family_calendar_sync.log")

struct Event: Codable {
    let key: String
    let title: String
    let start: TimeInterval
    let end: TimeInterval
    let location: String
    let notes: String
    let sig: String
}

func ensureAppDir() {
    do {
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    } catch {
        print("FATAL could not create app directory: \(error.localizedDescription)")
        exit(1)
    }
}

func log(_ msg: String) {
    ensureAppDir()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let stamp = formatter.string(from: Date())
    let line = "[\(stamp)] \(msg)\n"

    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                do {
                    try h.seekToEnd()
                    try h.write(contentsOf: data)
                    try h.close()
                } catch {
                    print("LOG WRITE ERROR: \(error.localizedDescription)")
                }
            }
        } else {
            do {
                try data.write(to: logURL)
            } catch {
                print("LOG CREATE ERROR: \(error.localizedDescription)")
            }
        }
    }
}

@discardableResult
func shell(_ cmd: String, _ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: cmd)
    t.arguments = args

    let out = Pipe()
    let err = Pipe()
    t.standardOutput = out
    t.standardError = err

    do {
        try t.run()
        t.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (t.terminationStatus, stdout, stderr)
    } catch {
        return (1, "", error.localizedDescription)
    }
}

#Password for email set in keychain.  Can also enter each time.
func getPassword() -> String? {
    let result = shell("/usr/bin/security", [
        "find-generic-password",
        "-a", smtpUsername,
        "-s", keychainService,
        "-w"
    ])
    return result.status == 0 ? result.stdout : nil
}

func stableKey(title: String, start: Date, end: Date) -> String {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(cleanTitle)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))"
}

func stableSignature(title: String, start: Date, end: Date, location: String, notes: String) -> String {
    return "\(title)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(location)|\(notes)"
}

func loadState() -> [String: Event] {
    ensureAppDir()

    guard FileManager.default.fileExists(atPath: stateURL.path) else {
        log("No existing state file at \(stateURL.path)")
        return [:]
    }

    do {
        let d = try Data(contentsOf: stateURL)
        let decoded = try JSONDecoder().decode([String: Event].self, from: d)
        log("Loaded \(decoded.count) events from state")
        return decoded
    } catch {
        log("ERROR loading state: \(error.localizedDescription)")
        return [:]
    }
}

func saveState(_ s: [String: Event]) {
    ensureAppDir()

    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let d = try enc.encode(s)
        try d.write(to: stateURL, options: .atomic)
        log("Saved \(s.count) events to state at \(stateURL.path)")
    } catch {
        log("ERROR saving state: \(error.localizedDescription)")
        print("STATE SAVE ERROR: \(error.localizedDescription)")
    }
}

func utc(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: d)
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: ";", with: "\\;")
     .replacingOccurrences(of: ",", with: "\\,")
     .replacingOccurrences(of: "\n", with: "\\n")
}

func ics(_ e: Event, method: String) -> String {
    var l = [
        "BEGIN:VCALENDAR",
        "METHOD:\(method)",
        "VERSION:2.0",
        "PRODID:-//Family Calendar Sync//EN",
        "BEGIN:VEVENT",
        "UID:\(esc(e.key))",
        "DTSTAMP:\(utc(Date()))",
        "DTSTART:\(utc(Date(timeIntervalSince1970: e.start)))",
        "DTEND:\(utc(Date(timeIntervalSince1970: e.end)))",
        "SUMMARY:\(esc(e.title))",
        "SEQUENCE:0"
    ]
    if !e.location.isEmpty { l.append("LOCATION:\(esc(e.location))") }
    if !e.notes.isEmpty { l.append("DESCRIPTION:\(esc(e.notes))") }
    if method == "CANCEL" { l.append("STATUS:CANCELLED") }
    l += ["END:VEVENT", "END:VCALENDAR", ""]
    return l.joined(separator: "\r\n")
}

func buildEmail(subject: String, body: String, ics: String) -> String {
    let method = ics.contains("METHOD:CANCEL") ? "CANCEL" : "REQUEST"
    let boundary = "BOUNDARY-\(UUID().uuidString)"

    return """
From: \(senderEmail)
To: \(recipientEmail)
Subject: \(subject)
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="\(boundary)"

--\(boundary)
Content-Type: text/plain; charset=utf-8

\(body)

--\(boundary)
Content-Type: text/calendar; method=\(method); charset=utf-8
Content-Transfer-Encoding: 8bit
Content-Disposition: attachment; filename="invite.ics"

\(ics)
--\(boundary)--
"""
}

func smtpSendRawMessage(_ rawMessagePath: String, password: String) -> (Bool, String) {
    let py = """
import smtplib, ssl, sys

msg = open(r'\(rawMessagePath)', encoding='utf-8').read()

try:
    s = smtplib.SMTP(r'\(smtpHost)', \(smtpPort), timeout=60)
    s.ehlo()
    s.starttls(context=ssl.create_default_context())
    s.ehlo()
    s.login(r'\(smtpUsername)', r'''\(password)''')
    s.sendmail(r'\(senderEmail)', [r'\(recipientEmail)'], msg)
    s.quit()
    print("OK")
except Exception as e:
    print(str(e))
    sys.exit(1)
"""
    let tmpPy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".py")
    try? py.write(to: tmpPy, atomically: true, encoding: .utf8)
    let result = shell("/usr/bin/python3", [tmpPy.path])
    try? FileManager.default.removeItem(at: tmpPy)
    return (result.status == 0, result.status == 0 ? result.stdout : (result.stderr.isEmpty ? result.stdout : result.stderr))
}

func sendWithBackoff(subject: String, body: String, icsContent: String) {
    guard let pw = getPassword() else {
        log("ERROR no SMTP password in Keychain")
        exit(1)
    }

    sleep(baseSendDelaySeconds)

    let raw = buildEmail(subject: subject, body: body, ics: icsContent)
    let tmpMsg = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".eml")
    try? raw.write(to: tmpMsg, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmpMsg) }

    let delays = [UInt32(0)] + retryDelaysSeconds
    var lastError = "unknown send failure"

    for (idx, delay) in delays.enumerated() {
        if delay > 0 {
            log("Backing off \(delay)s before retry \(idx)")
            sleep(delay)
        }

        let result = smtpSendRawMessage(tmpMsg.path, password: pw)
        if result.0 {
            log("Email send succeeded")
            return
        } else {
            lastError = result.1
            log("WARN send attempt \(idx + 1) failed: \(lastError)")
        }
    }

    log("ERROR all send attempts failed: \(lastError)")
    exit(1)
}

ensureAppDir()
log("Run started")
print("App dir: \(appDir.path)")
print("State path: \(stateURL.path)")

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false

if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in
        granted = ok
        sem.signal()
    }
} else {
    store.requestAccess(to: .event) { ok, _ in
        granted = ok
        sem.signal()
    }
}
sem.wait()

if !granted {
    log("ERROR no calendar access")
    exit(1)
}

guard let calendar = store.calendars(for: .event).first(where: { $0.title == calendarName }) else {
    log("ERROR no Family calendar")
    exit(1)
}

let now = Date()
guard let end = Calendar.current.date(byAdding: .month, value: lookaheadMonths, to: now) else {
    log("ERROR could not compute lookahead date")
    exit(1)
}

let pred = store.predicateForEvents(withStart: now, end: end, calendars: [calendar])
let events = store.events(matching: pred).filter { event in
    if let eventEnd = event.endDate {
        return eventEnd > now
    }
    return false
}

log("Fetched \(events.count) events in next \(lookaheadMonths) months")

let old = loadState()
var new: [String: Event] = [:]

for e in events {
    guard let startDate = e.startDate,
          let endDate = e.endDate else {
        log("Skipping event with missing dates")
        continue
    }

    let title = e.title ?? ""
    let location = e.location ?? ""
    let notes = e.notes ?? ""

    let ev = Event(
        key: stableKey(title: title, start: startDate, end: endDate),
        title: title,
        start: startDate.timeIntervalSince1970,
        end: endDate.timeIntervalSince1970,
        location: location,
        notes: notes,
        sig: stableSignature(title: title, start: startDate, end: endDate, location: location, notes: notes)
    )

    new[ev.key] = ev
}

saveState(new)

for (key, ev) in new {
    if old[key] == nil {
        sendWithBackoff(
            subject: "New: \(ev.title)",
            body: ev.title,
            icsContent: ics(ev, method: "REQUEST")
        )
        log("NEW \(ev.title)")
    } else if old[key]?.sig != ev.sig {
        sendWithBackoff(
            subject: "Update: \(ev.title)",
            body: ev.title,
            icsContent: ics(ev, method: "REQUEST")
        )
        log("UPDATE \(ev.title)")
    }
}

for (key, oldEvent) in old {
    if new[key] == nil && oldEvent.end > now.timeIntervalSince1970 {
        sendWithBackoff(
            subject: "Cancel: \(oldEvent.title)",
            body: oldEvent.title,
            icsContent: ics(oldEvent, method: "CANCEL")
        )
        log("CANCEL \(oldEvent.title)")
    }
}

log("DONE")
print("DONE")
---


