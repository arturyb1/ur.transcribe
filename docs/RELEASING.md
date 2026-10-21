# Releasing

Releases are signed with a Developer ID, notarized by Apple, and stapled, so they open with a double-click and no security warning. This needs a paid Apple Developer Program membership.

## One-time setup

1. **Create a Developer ID Application certificate.** In Xcode, open Settings, then Accounts. Select your team, click **Manage Certificates**, click **+**, and choose **Developer ID Application**. Only the team's Account Holder can create one. When it's done, this lists it:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Save notary credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security, App-Specific Passwords). Then run this and paste the password when asked:

   ```bash
   xcrun notarytool store-credentials urtranscribe-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

   The password is stored in your keychain. The release script only refers to the profile name.

## Cutting a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, then commit.
2. Create the GitHub release (tag `v<version>`) with notes.
3. Build, notarize, and attach the files:

   ```bash
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/release.sh --upload
   ```

Notarization usually takes a few minutes per submission. The script submits twice (the app, then the DMG) and checks both with Gatekeeper before uploading.

A side benefit: with a stable Developer ID signature, macOS keeps the app's permissions across updates.
