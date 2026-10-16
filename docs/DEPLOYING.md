# Deploying with Jamf Pro

Everything a service desk Mac needs, deployed so nobody has to click anything. Each release on GitHub has the three files used below:

- `Amphora-<version>.pkg`: installs the app in Applications and the `amphora` command-line tool in `/usr/local/bin`. Signed and notarized.
- `Amphora-FullDiskAccess.mobileconfig`: the Full Disk Access profile for that release.
- `Amphora-<version>.pkg.sha256`: checksum.

## 1. Read-only API client

In Jamf Pro → Settings → **API Roles and Clients**:

1. Create a role with only **Read Mobile Devices**. Add **Read Computers** if Amphora should include Apple silicon Macs (`JamfIncludeMacs`).
2. Create a client with that role, enable it, and generate a secret.

Amphora reads model identifiers and whether each device is managed. It never writes to Jamf Pro.

## 2. Package

Upload the `.pkg` (Settings → Packages) and install it with a policy scoped to the service desk Macs.

## 3. Full Disk Access (PPPC)

Configuration Profiles → **Upload** `Amphora-FullDiskAccess.mobileconfig`, scoped to the same Macs.

This lets Amphora place restore files in Apple Configurator's cache, so restores start without a download. macOS never prompts for Full Disk Access, so without the profile someone must grant it by hand in System Settings.

The profile contains the release's code requirement. It keeps matching later releases as long as they're signed by the same Developer ID.

## 4. Settings

Configuration Profiles → **Application & Custom Settings** → Upload, with preference domain `consulting.techne.amphora`. Start from [`examples/consulting.techne.amphora.plist`](examples/consulting.techne.amphora.plist): set `JamfURL` and `JamfClientID`, and remove any key you don't want to enforce. Enforced settings show as locked in the app.

The client **secret** is not part of the profile: profiles are readable on the Mac. Enter it once in Amphora → Settings → Models. It's kept in the login Keychain.

## 5. Keep it running

Amphora registers itself to open at login on first launch. To stop users turning that off, add a **Managed Login Items** payload with the bundle identifier `consulting.techne.amphora`.

## Headless alternative

On a Mac that should only hold files, without the app running, use the command-line tool from a policy or a LaunchDaemon:

```sh
JAMF_URL=https://yourorg.jamfcloud.com \
JAMF_CLIENT_ID=… JAMF_CLIENT_SECRET=… \
/usr/local/bin/amphora sync --from-jamf --store "/Users/Shared/Amphora"
```

Keep the secret out of policy scripts where you can: Jamf script parameters are visible to admins and in logs.

## Checklist

- [ ] API role with Read Mobile Devices only (plus Read Computers for Macs), client enabled
- [ ] Package policy scoped to the service desk Macs
- [ ] Full Disk Access profile from the same release
- [ ] Settings profile with Jamf address and client ID
- [ ] Secret entered once in the app
- [ ] Optional: Managed Login Items payload
