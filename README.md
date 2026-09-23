<p align="center">
  <img src="assets/icon.png" width="96" alt="RichPresence icon">
</p>

<h1 align="center">RichPresence</h1>

<p align="center">
  A tiny Windows launcher for <b>Genshin Impact</b> that shows your game on Discord.<br>
  Your username, Adventure Rank, UID and World Level, <b>next to</b> the song you're playing on Apple Music.
</p>

```
 Playing Genshin Impact              Listening to <artist>
 YourName - AR 60                    <song>
 UID 123456789 - WL 8                <the current lyric line>
```

It works like a game bootstrapper: open RichPresence, click **Launch Genshin**, and your Discord updates while you play.
It sits in your system tray, and can quit by itself when the game closes.

- No login, no passwords, no cookies. It never touches your Genshin account.
- Your profile comes from the public [Enka.Network](https://enka.network) API, using only your UID.
- It only talks to the Discord app running on your PC.
- Windows 10 / 11. Discord **desktop** app (the website version can't show activity).

---

## Quick start (5 minutes)

### 1. Download

Grab **`RichPresence.exe`** from the [Releases page](../../releases/latest) and put it anywhere (a folder on your desktop is fine).

> Windows SmartScreen may say "Windows protected your PC" because the file is new and unsigned. Click **More info → Run anyway**.
> Don't trust it? Read [`src/RichPresence.ps1`](src/RichPresence.ps1), it's the whole program, or [build it yourself](#build-it-yourself).

### 2. Make your own Discord "app" for Genshin (1 minute, free)

Discord shows a second activity only if it comes from a second Discord application. That's what makes the Genshin card and the music card appear **side by side**.

1. Go to <https://discord.com/developers/applications> and log in.
2. Click **New Application**, name it **Genshin Impact** (this name is what people see after "Playing"), tick the box, **Create**.
3. On the **General Information** page, click **Copy** under **APPLICATION ID**.

That number (17–20 digits) is your **Genshin app ID**.

### 3. Fill in RichPresence

Open `RichPresence.exe`:

| Field | What to put | Where to find it |
|---|---|---|
| **Genshin app ID** | The Application ID you just copied | Discord Developer Portal, step 2 |
| **Your UID** | Your 9-digit Genshin UID | Bottom-right corner of the Genshin screen |
| **Game or HoYoPlay launcher** | Click **Detect**. If it says it can't find it, click **Browse** and pick `GenshinImpact.exe` or `launcher.exe` | Usually `C:\Program Files\HoYoPlay` |
| **Music / apps app ID** | Leave as is | The default (Cider's public app) works fine. Only change it if you made your own app for music |

### 4. Turn on your Character Showcase in Genshin

RichPresence reads your public profile, so it has to be public:

**In-game: Profile → Edit → Character Showcase → turn on "Show Character Details"** (wording can vary a little between versions).
No showcase = no name / AR / WL. You'd only see "Exploring Teyvat".

### 5. Play

Click **Launch Genshin**. That starts the game (or HoYoPlay, then press Play) and turns the presence on.
Check your Discord profile. You never see your own activity in the member list, but you do on your profile.

Also in Discord: **Settings → Activity Privacy → "Share your detected activity with others"** must be on.

---

## Everyday use

- **Desktop shortcut:** click **Desktop shortcut (launch)** in the window. It makes a *Genshin (RichPresence)* icon that launches the game and the presence in one click.
- **Options** in the window: show/hide Apple Music, lyrics, album art, the current app, start with Windows, quit when Genshin closes, hide to tray.
- **Tray icon:** right-click for Open / Launch Genshin / Start-Stop / Quit.
- **Command-line:** `RichPresence.exe -Launch` launches the game right away. `-Headless` runs with no window.

Settings are saved in `%APPDATA%\RichPresence\settings.json`. Delete that file to reset.

## What it can show

| Situation | Discord shows |
|---|---|
| Genshin running | **Playing Genshin Impact**, with your name, AR, UID and WL |
| Apple Music playing (Microsoft Store app) | **Listening to** the artist, with song, album art, progress and the synced lyric line |
| Neither, but you're using an app | The app you're using (VS Code, Chrome, ...) with an icon and elapsed time |

Genshin and music can show at the same time. If you don't set a Genshin app ID, the Genshin card replaces the music card instead.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing shows on Discord | Use the Discord **desktop app** (not the browser), and turn on Activity Privacy (step 5). |
| Only **one** card shows | The Genshin app ID is empty, wrong, or the same as the music app ID. |
| Shows "Exploring Teyvat" and no name | Character Showcase isn't public in-game. Turn it on and wait up to 10 minutes. |
| Wrong name after "Playing" | Rename your Discord application to **Genshin Impact** in the Developer Portal. |
| "Couldn't start it" when launching | Genshin/HoYoPlay may need admin. Right-click RichPresence → **Run as administrator**. |
| Music doesn't show | Only the Microsoft Store **Apple Music** app is supported (not old iTunes). |
| Status seems stuck | Discord limits how often activity can update. It can lag a few seconds. |
| Log says "Waiting for Discord" | Start Discord, then it connects by itself. |

## Privacy

- No accounts, tokens or cookies are ever asked for.
- Network calls: `discord` (local pipe only), `enka.network` (your public Genshin profile), `itunes.apple.com` (album art), `lrclib.net` (lyrics), `google.com/s2/favicons` (app icons).
- Nothing is sent to the author. There is no telemetry.

## Build it yourself

```powershell
git clone https://github.com/OWNER/RichPresence.git
cd RichPresence
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

That installs the [`ps2exe`](https://github.com/MScholtes/PS2EXE) module for your user and writes `dist\RichPresence.exe`.
You can also just run the script directly: `powershell -ExecutionPolicy Bypass -File src\RichPresence.ps1`.

## Not affiliated

This is a fan project. It isn't affiliated with or endorsed by HoYoverse, Discord or Apple.
It does not read game memory, inject into the game, or modify any game files. It only checks whether the game process is running.

## License

[MIT](LICENSE)
