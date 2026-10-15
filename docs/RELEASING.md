# Releasing

A checklist for cutting a release. Do every step, every time.

1. **Test on a clean Mac.** Fresh folder, run the CLI with `--dry-run`, then a real sync of two or three models. Restore one device from the result.
2. **Bump the version** in three places:
   - `Sources/IPSWMirrorCore/Models.swift` (`IPSWMirror.version`)
   - `App/project.yml` (`MARKETING_VERSION`, and increase `CURRENT_PROJECT_VERSION`)
   - `CHANGELOG.md` (move Unreleased items under the new version, with today's date)
3. **Commit** with the message `Release vX.Y.Z`.
4. **Tag:** `git tag vX.Y.Z && git push origin main --tags`.
5. **Build, sign, notarize** (from v0.2: Developer ID certificate required)
   - Archive the app in Xcode, or with `xcodebuild archive`.
   - Build the `.pkg` with `pkgbuild` / `productbuild` and sign it with your Developer ID Installer certificate.
   - Run `xcrun notarytool submit … --wait`, then `xcrun stapler staple`.
6. **Publish** a GitHub Release from the tag. Paste the CHANGELOG section and attach the `.pkg`.
7. **Announce** in the MacAdmins Slack when it's a notable release.

## Rules of thumb

- **Version numbers:**
  - patch (0.1.1) for fixes,
  - minor (0.2.0) for features,
  - major (1.0.0) once settings and behaviour are stable.
- Never push credentials, client names or hostnames. Check `git diff --staged` before every commit.
