# Discord Social SDK (not included)

Discord's Social SDK can't be redistributed in this public repository.

- **GitHub builds** copy `discord_partner_sdk.xcframework` from the private repo
  `noice912/RichPresence-sdk` (folder `ios/`), using the `SDK_REPO_TOKEN` secret.
- **Building on a Mac yourself:** put `discord_partner_sdk.xcframework` (from
  `discord_social_sdk/lib/release/` in the SDK download) in this folder, then
  `brew install xcodegen && xcodegen` in `ios/`.
