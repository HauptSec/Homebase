# Homebase

A shared home for plans, meals, bills, tasks, and groceries. Native SwiftUI for iPhone and iPad, backed by a Dockerized API on your own server.

## What’s included

- **Today:** upcoming and overdue household items, quick add, sync status.
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
