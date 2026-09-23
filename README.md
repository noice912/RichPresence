<p align="center">
  <img src="assets/icon.png" width="96" alt="RichPresence icon">
</p>

<h1 align="center">RichPresence</h1>

<p align="center">
  A game library that shows what you're playing on Discord.<br>
  It finds the games installed on your PC, like the NVIDIA app does, and shows <b>"Playing &lt;game&gt;"</b> while they run.<br>
  It can also show your <b>Apple Music</b> song (with lyrics) and the <b>app you're using</b>, all at the same time.
</p>

**No setup, no Discord developer account, no IDs to copy.** Download, open, done.

- Detects **Steam, Epic, GOG, Riot, Xbox, HoYoPlay** and games in your `Games` folders, plus any game or folder you add yourself
- Matches each game to its **official Discord app** (Discord's own public list), so you get the real game name and icon that everyone sees
- Up to **three cards at once**: your game, your music, and your current app
- **Play** button on every tile, plus optional desktop shortcuts per game
- Genshin Impact bonus: shows your name, Adventure Rank, UID and World Level
- Lives in the tray, can start with Windows, and can quit when your game closes

> It only *looks* at which programs are running. It doesn't inject into games, read game memory, or touch game files. See [Why does my antivirus complain?](#why-does-my-antivirus-complain)

---

## Get started

1. Download **`RichPresence.exe`** from the [latest release](../../releases/latest) and put it anywhere.
2. Open it. Your games appear in a few seconds.
3. Click **Start presence** (or just click **Play** on a game).

That's all. In Discord, make sure **Settings → Activity Privacy → Share your detected activity with others** is on, and use the Discord **desktop** app (the website can't show activity).

### "RichPresence.exe isn't commonly downloaded" - is that normal?

Yes. Browsers and Windows show this for any **new, unsigned** program that few people have downloaded yet. It's a reputation check, not a virus detection. Here's how to get past it:

1. **In your browser** (Edge/Chrome): open the downloads list, click **`...`** next to `RichPresence.exe` → **Keep** → **Show more** → **Keep anyway**.
2. **When you open it**, if Windows says *"Windows protected your PC"*: click **More info** → **Run anyway**.

Don't want to trust a binary? Read the [source](src/RichPresence.ps1) and [build it yourself](#build-it-yourself). The EXE is built from that file by GitHub Actions, which you can see on the [Actions tab](../../actions).

## Using it

| | |
|---|---|
| **Games tab** | Every detected game is a tile. **Play** launches it. Untick **Show on Discord** to hide a game. Right-click a tile for *Create desktop shortcut* or *Open install folder*. |
| **Missing a game?** | Click **+ Add game** and pick its `.exe`, or add a folder in **Settings** (each sub-folder counts as a game), then **Rescan**. |
| **Music & Apps tab** | Turn Apple Music, lyrics, album art and the "current app" card on or off. |
| **Settings tab** | Optional Genshin UID, extra game folders, start with Windows, tray behavior. |
| **Log tab** | What the app is doing, which is handy if something looks off. |

Your settings are stored in `%APPDATA%\RichPresence`. Delete that folder to reset everything.

## Genshin Impact stats (optional)

Put your **UID** (bottom-right corner in-game) into **Settings** and your Genshin card shows:

```
 Playing Genshin Impact
 YourName - AR 60
 UID 123456789 - WL 8
```

This reads your public profile from [Enka.Network](https://enka.network) (no login). In Genshin, turn on **Profile → Edit → Character Showcase**, otherwise there's nothing public to read.

## How it works

| Card | What triggers it |
|---|---|
| **Game** | A process from your library is running. Uses that game's official Discord app if Discord has one, otherwise a generic "game" card. |
| **Music** | The Microsoft Store **Apple Music** app is playing. |
| **App** | You're focused on another program (VS Code, Chrome, ...). Kept for a few minutes when you alt-tab to Discord. |

Discord shows one activity per Discord application, so each card uses its own application. Those IDs are built into the app. They're public identifiers, not secrets, and presence is set by *your* Discord client, so thousands of people can share them without ever overlapping.

## Why does my antivirus complain?

Small unsigned tools that watch running programs and talk to Discord sometimes get flagged by heuristic scanners. This one isn't malware, and you don't have to take that on faith:

- **The whole program is one readable file:** [`src/RichPresence.ps1`](src/RichPresence.ps1). The EXE is that script wrapped by [PS2EXE](https://github.com/MScholtes/PS2EXE), and PS2EXE-built files are a common false-positive target.
- **What it does:** list running process names, read the focused window's title, read the Apple Music "now playing" info from Windows, and talk to the Discord app on your PC over its local pipe.
- **What it never does:** inject code, read or write game memory, modify game files, log keystrokes, or ask for passwords/tokens.
- **Network calls:** `discord.com` (the public list of known games), `enka.network` (Genshin profile, optional), `itunes.apple.com` (album art), `lrclib.net` (lyrics), `google.com/s2/favicons` (app icons). Nothing is sent to the author.
- **Verify or build it yourself:** releases are built by GitHub Actions from this repo, so you can [build it yourself](#build-it-yourself) and compare. You can also upload the EXE to [VirusTotal](https://www.virustotal.com) and see that the few flags, if any, are generic heuristics from PS2EXE.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing shows on Discord | Use the Discord **desktop** app and turn on Activity Privacy. Then check the sidebar says **Presence on**. |
| A game is missing | **+ Add game**, or add its folder in Settings, then **Rescan**. |
| A game shows as a "generic game" | Discord doesn't have an official app for it. It still shows, just without its own icon. |
| Music doesn't show | Only the Microsoft Store **Apple Music** app is supported (not old iTunes). |
| Genshin shows no name | Turn on **Character Showcase** in-game and enter your UID in Settings. |
| Play does nothing / asks for admin | Some launchers need admin. Right-click RichPresence → **Run as administrator**. |
| Status lags | Discord limits how often activity can update. It can take a few seconds. |

## Build it yourself

```powershell
git clone https://github.com/noice912/RichPresence.git
cd RichPresence
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

That installs the [`ps2exe`](https://github.com/MScholtes/PS2EXE) module for your user and writes `dist\RichPresence.exe`.
Or skip building and run it directly: `powershell -ExecutionPolicy Bypass -File src\RichPresence.ps1`.

Debug options: `-Headless` (no window), `-ScanOnly` (print detected games), `-Play "<game id>"` (launch a game).

## Not affiliated

A fan project, not affiliated with or endorsed by Discord, Apple, HoYoverse or any game publisher.

## License

[MIT](LICENSE)
