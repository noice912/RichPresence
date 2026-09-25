# Discord Social SDK (not included)

Discord's Social SDK can't be redistributed in this repository. To build the Android app with
Discord account linking:

1. Download `DiscordSocialSdk-<version>.zip` from the Discord Developer Portal
   (your application > Games > Social SDK > Downloads).
2. Put these in this folder:
   - `discord_partner_sdk.aar` (from `discord_social_sdk/lib/release/`)
   - `include/` (from `discord_social_sdk/include/`)
   - `jni/` (the `jni` folder inside `discord_partner_sdk.aar`; it's a zip)
3. Build: `gradle assembleRelease` in `android/`.

Without these files the app still builds, just without Discord linking (it logs what it would show).
