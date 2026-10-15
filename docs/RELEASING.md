# Releasing

A checklist for cutting a release. Do every step, every time.

## One-time setup

1. **Apple Developer Program** membership (paid). You need to be the Account Holder or an Admin.
2. In Xcode → Settings → Accounts → Manage Certificates → **+**, create:
   - **Developer ID Application** (signs the app and the CLI)
   - **Developer ID Installer** (signs the .pkg)
3. Create an app-specific password at [account.apple.com](https://account.apple.com) → Sign-In and Security, then store notarization credentials:
   ```sh
   xcrun notarytool store-credentials ipsw-mirror --apple-id <your Apple ID> --team-id <team ID>
   ```
4. `brew install xcodegen`

Check it all with a test package: `scripts/release.sh --unsigned` needs none of the above and shows whether the build and packaging work.

**Jamf-only builds before notarization is set up:** `scripts/release.sh --no-notarize` needs only steps 1 and 2. The result is Developer ID-signed, so its Full Disk Access profile stays valid across updates, and Jamf-installed packages aren't quarantined, so Gatekeeper doesn't block them. Don't publish these on GitHub: a downloaded copy would be blocked.

## Each release

1. **Test on a clean Mac.** Fresh store folder, sync two or three models, restore one device from the result.
2. **Bump the version** in:
   - `Sources/IPSWMirrorCore/Models.swift` (`IPSWMirror.version`)
   - `App/project.yml` (`MARKETING_VERSION`, and increase `CURRENT_PROJECT_VERSION`)
   - `CHANGELOG.md`: move the Unreleased items under `## [X.Y.Z] - YYYY-MM-DD`
3. **Build:** `scripts/release.sh`. It refuses to run if the versions disagree or the changelog has no section. It runs the tests, signs, notarizes and staples, and writes everything to `dist/`.
4. **Commit and tag:**
   ```sh
   git commit -am "Release vX.Y.Z"
   git tag vX.Y.Z && git push origin main --tags
   ```
5. **Publish:**
   ```sh
   gh release create vX.Y.Z dist/* --title "IPSW Mirror X.Y.Z" --notes-file <(awk '/^## \[X.Y.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md)
   ```
6. **Announce** notable releases in the MacAdmins Slack.

## Rules of thumb

- **Version numbers:**
  - patch (0.1.1) for fixes,
  - minor (0.2.0) for features,
  - major (1.0.0) once settings and behaviour are stable.
- Never commit credentials, client names or hostnames. Check `git diff --staged` before every commit.
- `dist/` and `build/` are build output and are not committed.
