# Homebase

A shared home for plans, meals, bills, tasks, and groceries. Native SwiftUI for iPhone and iPad, backed by a Dockerized API on your own server.

## What’s included

- **Today:** browse previous/next days with date arrows and return using Back to today. Today includes overdue household items; other dates show scheduled items, including completed items still retained on that date. Quick add and sync status remain available.
- **Calendar:** shared events and an opt-in two-way bridge to one shared iCloud calendar.
- **Dinners:** seven-day planner, saved meals, ingredients to groceries.
- **Bills:** amounts, currencies, weekly/monthly/yearly recurrence, reminders, payment dates.
- **Tasks:** dates, reminders, completion, recurrence.
- **Groceries:** General first, then stores alphabetically; items alphabetically within each store.
- **Sync:** durable offline edit queue, live foreground WebSocket invalidation, incremental pulls, idempotent writes, explicit conflict resolution.
- **Notifications:** APNs shared-change alerts and server-driven due reminders. Setup required.
- **Operations:** persistent SQLite/WAL volume, daily backups, CI-gated automatic deployment.

The app uses warm sage accents, native typography, familiar iOS controls, and system light/dark appearance. There are no household user accounts. Pair each phone once with a short-lived code; its credential stays in Keychain.

![Today screen with sample household data](docs/images/today-preview.png)

## Repository layout

- `ios/Homebase.xcodeproj` — native iOS app, iOS 17+
- `server/` — FastAPI, SQLite, APNs worker, local administration CLI
- `compose.yaml` — API and optional Cloudflare Tunnel
- `deploy/` — systemd user timers and deployment/backup scripts
- [Private wireless iOS updates](docs/AD_HOC_UPDATES.md) — installation, automatic builds, and signing renewal
- [Setup guide](docs/SETUP.md) — Cloudflare, Apple signing, push, pairing, recovery
- [Architecture and boundaries](docs/ARCHITECTURE.md)

## Local verification

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r server/requirements.txt
python -m unittest discover -s server/tests -v
xcodebuild -project ios/Homebase.xcodeproj -scheme Homebase \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
mkdir -p secrets
chmod 700 secrets
touch secrets/apns.p8
chmod 644 secrets/apns.p8
docker compose up -d --build api
```

The API binds to host loopback port 8092. Public access requires the optional tunnel; the iOS app requires HTTPS. All household routes require a device credential. `/health` returns only health, and `/v1/pair` accepts only a single-use server-generated invite.

## Status and limits

This is an initial implementation, not an App Store release. Build and server tests do not validate real APNs delivery, iCloud behavior, or installation on your phones. Complete the setup guide and its two-device acceptance checks before relying on Homebase for time-critical reminders.

The calendar bridge runs on one designated phone and covers the previous 30 days and next year. It mirrors event title, dates, all-day status, and notes. It edits recurring events as individual occurrences; create or modify series, attendees, alarms, and locations in Apple Calendar. Conflicting edits and missing iCloud events require review in Settings. iOS controls background execution; fixed polling while closed or force-quit cannot be guaranteed.

Bills track payment dates, not bank transactions or historical amount changes. Monthly recurrence clamps to valid dates (January 31 → February 28 → March 28). Offline reminders depend on the server having received the edit and the phone being reachable by APNs. No in-app login is required, so anyone who can unlock the phone can open its cached household data.

## Security reporting

Do not post secrets or household data in public issues. Report security concerns privately through the repository owner's GitHub contact channels. Never commit `.env`, pairing codes, APNs keys, tunnel credentials, databases, backups, or device caches.

### Automatic US holidays

Calendar includes read-only, all-day US holidays for the previous year through two years ahead, rolling forward automatically. Dates are calculated offline in the phone’s time zone. All 11 nationwide federal holidays are included, with separate Friday/Monday observed dates when fixed holidays fall on weekends, following [OPM’s federal holiday rules](https://www.opm.gov/policy-data-oversight/pay-leave/federal-holidays/). Regional holidays and one-off executive closures are not included.

Common observances include Valentine’s Day, St. Patrick’s Day, Good Friday, Western Easter, Earth Day, Cinco de Mayo, Mother’s Day, Flag Day, Father’s Day, Patriot Day, Halloween, Black Friday, Christmas Eve, and New Year’s Eve. These are labeled separately from federal holidays. Holidays appear on Today only on their date. They are a built-in Homebase calendar layer, not exported to the shared iCloud calendar, and do not create household change notifications or reminders.

### Simple Budget

Household → Budget tracks income and expenses with an amount, currency, date, optional reminder, and one-time/weekly/every-two-weeks/monthly/yearly recurrence. Existing bills remain expenses. Upcoming includes unpaid/unreceived overdue entries; completing an entry records the actual completion date and advances recurring entries once. Completed one-time entries remain accessible. Each repeating entry shows its next outstanding occurrence, rather than a projected ledger or bank balance. All phones should install the Budget update before using income or every-two-weeks recurrence.

### Dinner instructions

Dinner plans and saved meals have individual rows for Ingredients, Prep, and Cooking. Each section starts with one line; use + to append another and the minus button to remove a line. Blank rows are omitted when saving. Saved-meal selection and saving dinner favorites copy all three sections; adding groceries copies only ingredients. Existing meals and older offline caches remain compatible.

### Calendar events and appearance

Events support Starts/Ends, an All-Day toggle (off by default), Details, and Apple Maps place/address suggestions with an Open in Maps action. Addresses can be entered offline; suggestions require a network connection. All-day Ends is inclusive in the editor and stored as an exclusive next-day boundary for EventKit.

Repeat defaults to Never. Choose daily, weekly, every two weeks, monthly, yearly, or Custom (every 1–99 days/weeks/months/years; custom weekly rules can select weekdays). An optional last day ends the series. Month-end and leap-day rules skip missing dates. Timed series retain their creation/edit time zone and local clock time across daylight-saving changes. Each occurrence can be edited/deleted separately, or the entire series can be edited/deleted. Schedule changes reset individual exceptions; title/details changes preserve them. Calendar projects the previous year through two years ahead offline; series outside that window retain an editable anchor.

The iCloud bridge exports native EventKit recurrence rules and detached occurrence exceptions. Simple Apple-created series are adopted, including their individual edits. Simultaneous changes and missing occurrences require review. Apple-only advanced rules (such as nth-weekday patterns or count-based endings) remain in Apple Calendar; they are not silently flattened. Invitation-bearing series are not rebuilt by Homebase. Update all household clients before editing recurring series.

An event can have two distinct alerts, from the event time up to one week before. Homebase queues the next 60 local event alerts and refreshes them when the app opens/syncs (including best-effort background refresh); notification permission is required. On the phone running the calendar bridge, synced events use Apple Calendar alerts instead of duplicate Homebase alerts. Other phones schedule Homebase alerts; if they also enable Apple Calendar notifications for that shared calendar, both apps may notify. Native repeating Apple Calendar alarms continue independently of Homebase's local scheduling window.

Household → Settings → Appearance offers System, Light, and Dark. System is the default; changes apply immediately and persist per phone.

Validation includes deterministic recurrence/alert tests, server validation and exception conflicts, native field round-trips, and a simulator-only EventKit lifecycle smoke test. Run the latter using a Debug app with `--preview --native-series-smoke` on a simulator with Calendar access; it creates and removes a disposable local calendar and writes `Library/Application Support/native-series-smoke.txt` in the simulator app container. It never runs in a distribution build or on a physical phone.
