# Releasing

Releases are signed with a Developer ID, notarized by Apple, and stapled, so they open with a double-click and no security warning. This needs a paid Apple Developer Program membership.

Installed copies update themselves through [Sparkle](https://sparkle-project.org). The app reads `appcast.xml` from this repo's `main` branch, and installs an update only if its zip is signed with the project's EdDSA key.

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

3. **Create the update signing key** (once per maintainer machine; already done for this project):

   ```bash
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account urtranscribe
   ```

   It stores the private key in your login keychain and prints the public key, which belongs in `SUPublicEDKey` in `Resources/Info.plist`.

   **Back up the private key.** If it is lost, installed copies can't be updated again and everyone has to reinstall by hand. Export it, store it in a password manager, and delete the file:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account urtranscribe -x sparkle-private-key.txt
   ```

   To use it on another Mac, import it there with `-f sparkle-private-key.txt`.

## Cutting a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, then commit and push. Sparkle compares `CFBundleVersion`, so it must go up every release.
2. Create the GitHub release (tag `v<version>`) with notes. The notes become the update description people see in the app.
3. Build, notarize, attach the files, and publish the update:

   ```bash
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/release.sh --upload
   ```

Notarization usually takes a few minutes per submission. The script submits twice (the app, then the DMG) and checks both with Gatekeeper before uploading. Then it signs the zip with the update key, adds the release to `appcast.xml`, and pushes it. Installed copies see the update at their next daily check, or right away with **Check for Updates…**.

Keep the Mac unlocked while the script runs: the notary login and the update key are in the keychain.

A side benefit: with a stable Developer ID signature, macOS keeps the app's permissions across updates.
