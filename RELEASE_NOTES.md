## RichPresence 1.5.0

### Browser extension for Netflix and Hulu
Netflix and Hulu don't tell Windows what you're watching, so the new **RichPresence browser extension**
(`RichPresence-extension.zip`, for Edge, Chrome, Brave and Opera) reads it from the player page:
- the show and episode ("Stranger Things", "S4:E1 Chapter One: The Hellfire Club"), or the movie
- an exact progress bar, and the card goes away as soon as you pause
- it only talks to RichPresence on your own PC, which only accepts it from a browser extension

Install: unzip it, open `edge://extensions` (or `chrome://extensions`), turn on Developer mode,
**Load unpacked**, pick the folder. Click its icon to see that it's connected.

### From 1.4.1
- the app card no longer shows next to the Watching card
- no more "Watch" as a title or wrong posters; Edge tab titles are tidied up

## RichPresence 1.4.1

### Fixes
- Watching: the app card ("Microsoft Edge") no longer shows next to the Watching card
- Watching: pages that only say "Watch" (Hulu, Netflix) no longer show "Watch" as the title or a wrong poster
- Posters only match a show whose name is the start of the title (no more "Watch" -> "Watch the Skies")
- Browser tab titles no longer show "and 3 more pages - Personal - Microsoft Edge", and Edge's name is no longer garbled

## RichPresence 1.4.0

### Watching (Windows)
A **"Watching"** card for **Netflix, Hulu, Disney+, Prime Video, Max, Crunchyroll, Paramount+, Peacock,
Apple TV+ and Plex**, plus YouTube and Twitch (optional):
- shows the show or movie name, taken from what the site reports to Windows' media controls or from the tab title
- shows the show's poster, looked up on TVMaze (TV) and Cinemeta (movies), with the service's logo in the corner
- shows a progress bar when the site reports where you are
- works in Chrome, Edge, Firefox, Brave, Opera, Vivaldi and the services' Windows apps
- each service has its own Discord card with its name and logo (Plex, YouTube and Twitch use the app card)
- each part can be turned off under **Music & Apps**. It never reads the page itself, your cookies or your account.

### From 1.3.0
- **Custom status** tab: your own cards with your own text, pictures and buttons, shown separately or merged into one.

Every file is built by GitHub Actions from this repository's source.
