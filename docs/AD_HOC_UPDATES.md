# Private wireless iOS updates

Homebase uses Apple's **Ad Hoc / Release Testing** distribution for your registered household phones. It keeps bundle ID `xyz.hauptsec.homebase` and team `BH744E96JG`, preserving the app identity for updates and a potential future App Store migration. Packages are not published in the public GitHub repository.

## Updating your phone

Once the first ad hoc version is installed:

1. Open **Homebase → Household → Settings → App updates**.
2. Tap **Check for updates**. A newer release also appears as a banner on Today.
3. Finish syncing any pending changes and resolve conflicts.
4. Tap **Install update in Safari**. Safari opens a private page for that specific build.
5. Tap **Install update** on the page, confirm the iOS installation prompt, and return to the Home Screen. Open Homebase when installation finishes.

Do **not** uninstall the existing app. We keep the same bundle ID and signing team so iOS can update it in place. Verify local data and device pairing on the first development-to-ad-hoc upgrade. Server data remains on your home server regardless. Each download link lasts one hour; opening the app's update button creates a fresh link. Installation requires an explicit confirmation on the phone; this is not a silent automatic updater.

The first update from the older Xcode-installed version needs a link from the server administrator because that version has no update button:

```sh
ssh alex@10.10.1.120
cd ~/homebase
docker compose exec api python -m server.manage install-link
```

Open the printed URL in Safari on your iPhone. The static address `https://homebase.hauptsec.xyz/install` explains how to obtain a private link; it does not provide anonymous package access.

## Adding your wife's phone, or replacing a phone

Register its UDID in your Apple Developer account before exporting the next build. Xcode can register a connected phone, or you can register its identifier through Apple's developer portal. A package can only install on devices included in its embedded provisioning profile. Being paired with the Homebase API is separate from being registered with Apple.

Refresh the ad hoc provisioning profile to include the device, then force a release on the Mac:

```sh
python3 "$HOME/Library/Application Support/HomebaseRelease/checkout/distribution/auto_release.py" --force
```

Check the resulting profile includes the intended phone before sharing a link. If iOS requests Developer Mode, enable it through Settings → Privacy & Security and follow the system prompts. Homebase does not disable any device security setting automatically.

## Automatic release flow

The logged-in Mac runs a LaunchAgent every five minutes. This is a local build job, not a public GitHub self-hosted runner:

1. Fetch `main` into a dedicated clone under `~/Library/Application Support/HomebaseRelease/checkout`.
2. Require a successful **Verify** GitHub Actions run for that exact commit and wait for the home server to deploy the same commit.
3. If `ios/` or `distribution/` changed, archive a Release build with an increasing build number and export using `release-testing` signing.
4. Verify the IPA signature, bundle/team identity, ad hoc registered-device profile, production APNs entitlement, and expiry. Generate checksum metadata without exposing device identifiers.
5. Copy the package and metadata to a staging directory over SSH, then rename the immutable build directory into place.
6. Have the server verify package size and SHA-256, record the release transactionally, and queue a generic update notification for registered APNs devices.

The Mac must be awake, logged in, have network access, and have usable Xcode signing credentials. If it is asleep or its keychain/account requires attention, no new package is published; the installed version remains available. Apple may require an account sign-in, agreement acceptance, or profile/certificate renewal. No signing keys are uploaded to GitHub or the home server. The Mac's existing `gh` and SSH authentication are used.

To install/reinstall the job after cloning this repository on the build Mac:

```sh
python3 distribution/install_agent.py
```

Inspect it:

```sh
launchctl print "gui/$(id -u)/xyz.hauptsec.homebase.release"
cat "$HOME/Library/Application Support/HomebaseRelease/published.json"
tail -50 "$HOME/Library/Application Support/HomebaseRelease/agent.log"
tail -50 "$HOME/Library/Application Support/HomebaseRelease/agent-error.log"
cat "$HOME/Library/Application Support/HomebaseRelease/last-error.txt"
```

`last-build.log` contains the most recent archive/export output. `last-error.txt` is removed after a successful publication. A missing file means no recorded unresolved failure. The Mac keeps the latest two local build jobs; the server retains immutable published packages. Review disk use periodically.

## Signing expiry

Ad hoc validity is limited by the embedded provisioning profile and signing certificate, generally up to a year. Reinstalling the same package does not extend it. Before expiry, renew the profile/certificate and install a newly signed package on each phone. The Mac attempts renewal releases when under 30 days remain, but will refuse to publish an export that still has under 30 days of profile validity. Manual Apple account/profile maintenance may be needed.

The server sends renewal reminders as the latest published profile approaches 30, 7, and 1 day remaining. These depend on working APNs delivery and notification permission; monitor the build job as well. Check the install page's signing date when installing. A new package's production push token is registered automatically when Homebase opens.

## Security and operational details

- Household API tokens stay in Keychain and are never placed in install URLs.
- A download grant is random, hashed at rest, expires after one hour, and is fixed to one immutable build. Device-created grants stop working if that device is revoked. Administrator-generated grants are download-only and expire automatically.
- Install tickets cannot access household data. Treat them as private links: anyone with the link can download the IPA until it expires, although only Apple-registered devices can install it.
- Application access logging is disabled to avoid writing ticket URLs to API logs. Cloudflare still terminates TLS and may retain request information according to your account configuration. Pages use no-referrer/no-store headers and no third-party scripts or analytics.
- The server mounts `./releases` read-only into the unprivileged API. Publishing is performed through SSH and a local CLI, not a public upload endpoint.
- Release publication is monotonic, checksum-verified, and idempotent. A failed transfer does not replace a published build. Expired signed builds are not offered for installation.
- SQLite backups contain release metadata; package files live separately in `~/homebase/releases`. Keep both if you need to restore historical install links. Packages contain an embedded provisioning profile with registered-device identifiers, so keep backups private.

## Moving to an unlisted App Store app later

Keep the bundle ID, signing team, and compatible data model. Prepare an App Store archive, review materials, and the unlisted-distribution request. Test migration on one phone before moving the household. App Store installs can then use Apple's automatic update mechanism; this private release agent can be disabled with `launchctl bootout`.

References: [Apple's ad hoc provisioning](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/), [distribution options](https://help.apple.com/xcode/mac/current/en.lproj/devde46df08a.html), [wireless installation manifests](https://support.apple.com/en-gb/guide/deployment/depce7cefc4d/1/web).
