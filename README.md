# Family-calendar-sync
syncs iCal calendars to MS exchange
Local Calendar Sync (Apple → Exchange via Email)

Overview

This project is a lightweight, deterministic bridge between **Apple Calendar (macOS)** and **Exchange/Outlook calendars** using email-based invites.

It solves a common but frustrating problem:

> Native calendar syncing across ecosystems is unreliable.

Instead of relying on fragile integrations, this tool:
- reads events directly from Apple Calendar
- tracks changes locally
- sends only new/updated/cancelled events
- runs automatically on a schedule

Key Features

- Uses **EventKit** (no AppleScript, no UI automation)
- **State-driven sync** (no duplicate invites)
- Sends **ICS invites via SMTP**
- Handles:
  - new events
  - updates
  - cancellations
- Built-in **rate limiting + retry backoff**
- Runs automatically via **launchd**
- Fully local — no third-party services

Flow

Apple Calendar → EventKit → Sync Engine → ICS Generator → SMTP → Exchange

Components

| Component | Purpose |
|----------|--------|
| EventKit | Direct access to macOS calendar data |
| Sync Engine | Detects new/changed/deleted events |
| State Store | JSON file tracking prior runs |
| ICS Generator | Creates standard calendar invites |
| SMTP Sender | Sends invites without email client |
| launchd | Schedules daily execution |


How It Works

1. Event Extraction

Reads the **Family calendar** via EventKit:

store.events(matching: predicate)

2. Stable Event Identity
   
Events are keyed using:
title + start_time + end_time
This avoids reliance on unstable system IDs.

3. Change Detection
   
Each event gets a signature:
title + time + location + notes
Used to detect:
•	updates
•	no-op (unchanged)
•	deletions

4. State Tracking
   
Saved locally:

~/Library/Application Support/family_calendar_sync/state.json

This enables delta-based sync:
•	first run → sends all
•	later runs → sends only changes

5. Email Delivery
6. 
Uses SMTP (not Outlook/Mail):

•	TLS secured
•	no UI dependency
•	works headless

7. Rate Limiting
   
Prevents SMTP issues:
•	delay between sends
•	retry with backoff

8. Scheduling

launchctl unload ~/Library/LaunchAgents/com.family.calendar.sync.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.family.calendar.sync.plist

Runs daily via launchd:
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key><integer>17</integer>
    <key>Minute</key><integer>0</integer>
</dict>

 Installation
 
1. Save Script
   
nano ~/family_calendar_sync.swift
chmod +x ~/family_calendar_sync.swift

2. Create State Directory
   
mkdir -p ~/Library/Application\ Support/family_calendar_sync

3. Store SMTP Password in Keychain
   
security add-generic-password \
  -a "your_email@example.com" \
  -s "family-calendar-sync-smtp" \
  -w
  
4. Create LaunchAgent
   
nano ~/Library/LaunchAgents/com.family.calendar.sync.plist

5. Load Agent
   
launchctl load ~/Library/LaunchAgents/com.family.calendar.sync.plist

6. Test
   
launchctl start com.family.calendar.sync

Logs

~/Library/Application Support/family_calendar_sync/family_calendar_sync.log

Common Issues

Duplicate emails every run

→ state.json not saving or loading

Script not running

→ Check plist path:
/Users/<your-user>/family_calendar_sync.swift

SMTP failures

→ Add backoff or verify credentials in Keychain

Security Notes

•	Password stored in macOS Keychain
•	No credentials stored in code
•	Local-only execution (no external services)

Why This Exists

Calendar integrations almost work — until they don’t.
This project replaces:
•	inconsistent sync
•	UI automation hacks
•	client-dependent behavior
with a deterministic, observable system.

License

MIT (or your choice)
