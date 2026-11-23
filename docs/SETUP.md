# Homebase setup

## 1. Server and automatic deployment

The intended server is `10.10.1.120`, under `~/homebase`. The API is exposed only on `127.0.0.1:8092`; no router port-forward is needed.

```sh
git clone https://github.com/HauptSec/Homebase.git ~/homebase
cd ~/homebase
mkdir -p secrets
chmod 700 secrets
touch secrets/apns.p8
chmod 644 secrets/apns.p8
mkdir -p ~/.config/systemd/user
cp deploy/homebase-*.service deploy/homebase-*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now homebase-deploy.timer homebase-backup.timer
./deploy/auto-deploy.sh --force
```

The deployment script waits until GitHub Actions succeeds. User timers also require lingering to continue after logout (`loginctl show-user "$USER" -p Linger`; an administrator can enable it with `sudo loginctl enable-linger "$USER"`).

Check status:

```sh
cd ~/homebase
docker compose ps
curl --fail http://127.0.0.1:8092/health
systemctl --user status homebase-deploy.timer homebase-backup.timer
journalctl --user -u homebase-deploy.service -n 40 --no-pager
```

## 2. Cloudflare Tunnel — one-time setup

Use the Cloudflare account that manages `hauptsec.xyz`:

1. Open Cloudflare's **Networking → Tunnels** (some dashboards show **Zero Trust → Networks → Connectors**).
2. Create a **cloudflared** tunnel named **homebase**.
3. Copy only the tunnel token from the displayed installation command. Do not put it in GitHub, chat, or shell command history.
4. On the server, save it interactively:

```sh
cd ~/homebase
mkdir -p secrets
chmod 700 secrets
read -rsp 'Cloudflare tunnel token: ' HOMEBASE_TUNNEL_TOKEN; echo
(umask 077; printf '%s' "$HOMEBASE_TUNNEL_TOKEN" > secrets/cloudflare-tunnel-token)
unset HOMEBASE_TUNNEL_TOKEN
# cloudflared's container user must be able to read this file. The parent directory
# remains private on the host; only this individual file is mounted into the container.
chmod 644 secrets/cloudflare-tunnel-token
docker compose --profile tunnel up -d tunnel
```

5. In that tunnel, add a published application route:
   - Hostname: **homebase.hauptsec.xyz**
   - Service type: **HTTP**
   - Service URL: **api:8080** (Docker service name; not localhost)
6. Cloudflare creates the DNS route. Keep WebSockets enabled and bypass caching for this hostname. Do not place an interactive Cloudflare Access login in front of the API; the native client uses its device credential.
7. Verify `https://homebase.hauptsec.xyz/health` returns `{"status":"ok"}` and `/v1/sync` without a credential returns HTTP 401.

The public endpoint's security is HTTPS plus per-device authentication. It is not mTLS. Cloudflare Tunnel encrypts transport to the edge and requires no inbound firewall ports. [Cloudflare tunnel setup](https://developers.cloudflare.com/tunnel/get-started/).

## 3. Build and install the iOS app

1. Open `ios/Homebase.xcodeproj` in Xcode.
2. Select the **Homebase** target → **Signing & Capabilities** → your Apple Developer team.
3. Keep bundle ID **xyz.hauptsec.homebase** if available, or choose another and update `APNS_BUNDLE_ID` to match. The background task identifier can remain unchanged.
4. Enable the **Push Notifications** capability for the App ID. Background fetch and remote-notification modes are already declared.
5. Connect your iPhone and run the app. Repeat for your wife's phone. Alternatively archive a Release build and distribute it through TestFlight; TestFlight builds expire and need periodic replacement.
6. Generate one pairing code per phone on the server:

```sh
cd ~/homebase
docker compose exec api python -m server.manage invite
```

Enter `https://homebase.hauptsec.xyz`, a recognizable device name, and the code. Codes expire after ten minutes and work once. There is no recurring app login.

## 4. Apple Push Notification service

In the Apple Developer portal, create or reuse an **APNs authentication key** for your team. Enable APNs for the Homebase App ID. Download the `.p8` once and store it securely. Keep the key ID and team ID. Do not commit the key.

Copy it privately to the server:

```sh
scp /path/to/AuthKey_YOURKEYID.p8 alex@10.10.1.120:homebase/secrets/apns.p8
ssh alex@10.10.1.120
cd ~/homebase
# The API runs as UID 10001; keep the secrets directory private and mount read-only.
chmod 644 secrets/apns.p8
cp .env.example .env
chmod 600 .env
nano .env
```

Uncomment and fill:

```dotenv
APNS_KEY_FILE=/run/secrets/apns.p8
APNS_KEY_ID=YOUR_KEY_ID
APNS_TEAM_ID=YOUR_TEAM_ID
APNS_BUNDLE_ID=xyz.hauptsec.homebase
```

Then run `docker compose up -d --force-recreate api`, open each phone's Homebase Settings, and enable notifications. Debug builds register for sandbox APNs; Release/TestFlight builds register for production APNs. Never distribute a Debug build signed with a production push profile; the entitlements and APNs environment must agree.

[Apple's APNs token guidance](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).

## 5. Shared iCloud calendar

Create/share a calendar in Apple Calendar and accept the invitation on the other phone. On **one** phone, open Homebase → Household → Settings → Choose calendar. Grant access and select that shared calendar under the iCloud source. The other phone consumes Homebase's synced events and should not claim the bridge.

The first connection imports the last 30 days and next year of this calendar and exports existing Homebase events into it. Choose carefully. Homebase supports native repeating series in Apple Calendar, with edits to one occurrence or the entire series. Advanced Apple recurrence rules that Homebase cannot represent remain managed in Apple Calendar. Review calendar conflicts or missing events in Settings. Background sync is discretionary, especially after force-quitting the app.

## 6. Acceptance checks on both phones

- Add a grocery on A; verify it appears live on B and sends a notification when B is backgrounded.
- Turn off networking on A, edit two items, force-close/reopen, then reconnect. Confirm edits survive and sync once.
- Edit the same item offline on both phones. Confirm a review choice appears and inspect both versions.
- Create, edit, and delete an event in Homebase and Apple Calendar. Confirm changes on both phones; confirm missing Apple events via Settings.
- Create a small test bill with a near-term reminder, mark paid, verify payment history and next due date.
- Restart the container and verify data remains. Create a backup and test restoring a copy before depending on it.
- Test revoked device access, expired pairing codes, and access without credentials.

## 7. Device administration and backups

```sh
docker compose exec api python -m server.manage devices
docker compose exec api python -m server.manage revoke DEVICE_UUID
docker compose exec api python -m server.manage backup /backups/manual.sqlite
```

There are daily and pre-deployment backups inside the persistent `homebase_homebase-backups` Docker volume. They contain all household data and device credential hashes. Copy them to encrypted off-host storage; this repository does not configure an off-site destination automatically.

To export one backup without printing its contents:

```sh
mkdir -p private-backups
chmod 700 private-backups
docker compose cp api:/backups/manual.sqlite private-backups/manual.sqlite
chmod 600 private-backups/manual.sqlite
```

`private-backups` must remain outside public source control (or use a path outside the repository). To restore, stop the API, back up the current volume, and restore a selected backup into `/data/homebase.sqlite` using a temporary Compose run. Remove stale WAL/SHM files only while the API is stopped:

```sh
docker compose stop api
docker compose run --rm --no-deps api python -c 'import sqlite3; from pathlib import Path; source=sqlite3.connect("/backups/manual.sqlite"); target=sqlite3.connect("/data/homebase.sqlite"); source.backup(target); target.close(); source.close(); print("restored")'
docker compose up -d api
```

A database rollback can put phone cursors ahead of restored history. **Do not reconnect phones after restore until their cache has been reset and any pending edits have been preserved.** This initial version does not automate rollback-aware client recovery; use a fresh app install/pairing after preserving any offline data. A restore drill must use disposable test data.

## Task completion identity

Task completion records include the tap time, the completing device ID, and its owner (Alex or Laura). The server determines the owner from the authenticated device, preserves completion details during later edits, and clears them when a task is reopened. Offline completions keep their original tap time; older app versions use the server receipt time. Tasks completed before tracking was introduced show that completion details are unavailable.

Named devices such as “Alex’s iPhone” are recognized automatically. For generically named phones or replacement devices, assign an owner locally on the server:

```sh
docker compose exec api python -m server.manage devices
docker compose exec api python -m server.manage device-owner DEVICE_ID Laura
```

Use `Alex` or `Laura`. Explicit assignments override the device name. Unassigned, unrecognized devices cannot sync new task completions until an owner is assigned. The app caches the owner during sync for offline display; the server verifies attribution when syncing.

## Shared task reminders

Deploy the updated server before installing the updated iOS app. Tasks support Alex, Laura, or no assigned owner. The active task list groups Alex, Laura, then Unassigned, sorting each group oldest first by due date when present or date added otherwise. Existing creation dates are backfilled from the first recorded server change.

In Apple Reminders, create an iCloud list named **Homebase - Tasks** and share it with the family. On one paired phone, open Homebase Settings → Shared Apple Reminders → Choose Homebase - Tasks, grant Reminders access, and select that list. Only one phone can bridge reminders; the calendar bridge can run on a different phone. Family invitations are managed in Apple Reminders.

The bridge syncs titles, notes, due dates, absolute reminder alerts, completion, and deletions. Owners are stored as a trailing `Homebase owner: Alex`, `Laura`, or `Unassigned` line in reminder notes; this is separate from Apple's native assignments. Completion imported from Apple is labeled “Completed in Apple Reminders” because EventKit does not identify the person who completed it. Native recurrence, subtasks, and native assignments are not mapped into Homebase. Existing Apple recurrence rules are preserved when editing supported fields.

Sync runs on app activation, during foreground refresh, on EventKit changes, and when iOS permits background refresh. Settings includes a manual sync button. Simultaneous edits and missing reminders require review in Settings; temporary iCloud omissions never automatically delete Homebase tasks. Disconnecting leaves both copies intact. Dinners are excluded from this list.

## Shared dinner reminders

Create a separate iCloud list named **Homebase - Dinners** in Apple Reminders, share it with the family, then select it under Homebase Settings → Homebase - Dinners on one paired phone. Deploy the server update before installing the app update. Task and dinner connections are independent and may run on different phones.

Each planned dinner becomes a reminder due on its meal day, without an artificial due time. Titles, notes, meal dates, alerts, completion, and deletions sync both ways across all weeks; moving to another week does not remove reminders. Ingredients, prep steps, and cooking instructions remain in Homebase and survive edits imported from Reminders. Saved favorite meals are excluded. New Apple reminders must have a due date before import. Removing the date from an existing linked dinner pauses that dinner for review instead of removing it from the plan. Missing reminders and conflicting edits use the same review flow as Tasks.

## Moving items between groups

Drag the handle on an active task or grocery item, or a planned dinner, onto a destination section header, row, or empty group. Tasks update their assigned owner; groceries update their store (General clears the store); dinners update their meal date while preserving the meal time and shifting any reminder by the same interval. Moves use the normal offline save queue and sync to the household and connected Reminders list. Existing date/alphabetical ordering within groups remains in effect. Empty owner groups, known grocery stores, General, and all seven dinner days remain available as destinations.

The **Completed Items** button at the top of the shopping list opens a separate history view, matching Completed tasks. Only items completed on the current local calendar day appear there; the view resets at midnight or when the app next becomes active. Historical records remain stored, and unchecking a visible item returns it to its store.

## Siri and Apple Intelligence

After installing this update, launch Homebase once. Its App Shortcuts are available to Siri and Shortcuts without manually building shortcuts: **Ask Homebase**, add a shopping item, plan dinner, add an event, add a task, update an item, and view a day plan. Say “Ask Homebase,” then ask your question naturally. The words in your question are not restricted to a predefined question list. The same question handler is under Household → Ask Homebase.

Open-ended answers use Apple's on-device Foundation Models framework on supported devices with iOS 26+ and Apple Intelligence enabled. The assistant starts from saved records and can retrieve additional records by category, owner, store, date, completion date, and text. It can combine categories, for example recipes with groceries or tasks with calendar plans. Retrieval is read-only; questions never mutate records. It reports offline data and unresolved conflicts, and marks incomplete/truncated search results. It cannot know facts absent from Homebase, such as pantry inventory, and AI-generated answers still need judgment. Ordinary add/update and day-plan actions work without the model.

On iOS 27+ when Siri AI is available, calendar and reminder App Schemas expose native create/update actions and searchable entities. Tasks, shopping lists, and dinners map to reminder lists; calendar events use calendar schemas. Homebase indexes entities in the device's Spotlight index and associates visible rows with their entity identifiers. Siri AI availability and language/device support are controlled by Apple. These features require Xcode 27 when building; older SDKs compile the standard App Shortcuts path.

Siri mutations validate fields and save through the regular offline queue. Updating re-resolves the saved ID, preserving recipe details and unrelated fields. Task completion uses the phone's configured owner. Repeating event edits, attendee management, location-trigger reminders, and unsupported flags/attachments must be handled in the app; Siri rejects unsupported inputs instead of silently discarding them. The current free-form question flow is read-only, while explicit add/update intents perform edits.

References: [Apple Intelligence and Siri AI](https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai), [App schemas](https://developer.apple.com/documentation/appintents/app-schema-domains), [Foundation Models tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling).

## Owner assignments after upgrading

Older app versions could advance their sync cursor while discarding fields introduced by a newer server, including task owners. This update replays the change log once after loading an older cache, keeping queued edits and conflicts intact. Queued edits from before task ownership preserve the server's owner rather than encoding an accidental clear. Open the updated app on each phone and let it sync; reinstalling or re-pairing is unnecessary.
