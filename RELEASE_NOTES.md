## RichPresence 1.2.1

### Automatic updates
- **Windows:** checks GitHub when it opens and every 6 hours. New versions are downloaded, checked
  against the SHA-256 checksum GitHub publishes, and installed with a quick restart, never while a
  game is running. Turn it off (or update by hand) in Settings.
- **Linux AppImage:** the same. The `.deb` shows when a new version is out.
- **Android:** the app downloads and verifies the new APK, then opens Android's installer
  (Android always asks you to confirm).
- **iPhone:** not possible for sideloaded apps; install the new `.ipa` with Sideloadly.

### From 1.2.0
- Windows and Linux let Discord detect games it knows first (keeps Recent Activity and streaks),
  then show RichPresence's card after 2 minutes.
- Android (`RichPresence-android.apk`): link your Discord account; shows your game and your music.
- iPhone (`RichPresence-ios-sideload.ipa`, install with [Sideloadly](https://sideloadly.io)): Apple Music
  or Spotify with live lyrics, games through Shortcuts automations, two cards at once.
- Linux: `RichPresence-x86_64.AppImage` or `richpresence_1.2.1_amd64.deb`.

Every file is built by GitHub Actions from this repository's source.
