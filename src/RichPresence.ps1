<#
  RichPresence  -  a game library that shows what you're playing on Discord.

  Finds the games installed on your PC (Steam, Epic, GOG, Riot, HoYoPlay, Xbox, your own folders),
  matches each one to its official Discord app, and shows "Playing <game>" while it runs.
  Also shows Apple Music (with lyrics) and Genshin Impact stats (name, AR, UID, WL).

  Run as a script:  powershell -ExecutionPolicy Bypass -File RichPresence.ps1
  Or compile it:    .\build.ps1   ->  dist\RichPresence.exe

    -Play <id>   launch that game right away (the desktop shortcuts use this)
    -Headless    no window; run the presence engine in the console (debugging)
    -ScanOnly    print the detected games and exit (debugging)
#>
param(
    [string]$Play = '',
    [switch]$Headless,
    [switch]$ScanOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$DataDir      = if ($env:RICHPRESENCE_DATA) { $env:RICHPRESENCE_DATA } else { Join-Path $env:APPDATA 'RichPresence' }
$SettingsPath = Join-Path $DataDir 'settings.json'
$LibraryPath  = Join-Path $DataDir 'library.json'
# Discord app IDs are public (not secrets) and presence is set by each user's own Discord client,
# so everyone can share these without overlapping. Three apps = three cards at once.
$DefaultGameId  = '1552433095335215165'   # "RP 2" - card for games that have no official Discord app of their own
$DefaultMusicId = '1552437427828818050'   # "RP 3" - Apple Music card
$DefaultAppId   = '1544831111128154213'   # "Playing" - current-app card
$RepoUrl      = 'https://github.com/noice912/RichPresence'
$AppVersion   = '1.2.1'     # build.ps1 reads this; bump it for every release
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ===========================================================================
# Settings
# ===========================================================================
function New-DefaultSettings {
    [ordered]@{
        genshin_uid            = ''
        show_music             = $true
        show_lyrics            = $true
        show_album_art         = $true
        show_current_app       = $true
        disabled_games         = @()     # game ids switched off in the library
        extra_folders          = @()     # folders whose sub-folders are games
        custom_games           = @()     # [{name, exe}] added by hand
        start_presence_on_open = $true
        exit_when_game_closes  = $false
        start_with_windows     = $false
        official_to_discord    = $true      # let Discord detect games it knows first (keeps Recent Activity / streaks)
        official_delay_minutes = 2          # ...then show our own card after this long
        auto_update            = $true      # install new releases by itself (never while a game is running)
        close_to_tray          = $true
    }
}
function Load-Settings {
    $s = New-DefaultSettings
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        } catch {}
    }
    foreach ($k in 'disabled_games', 'extra_folders', 'custom_games') { $s[$k] = @($s[$k]) }
    return $s
}
# The Discord app IDs are fixed in the program - they are never read from (or written to) settings.
function Add-BuiltInIds($s) {
    $s['game_client_id']  = $DefaultGameId
    $s['music_client_id'] = $DefaultMusicId
    $s['app_client_id']   = $DefaultAppId
    $s
}
function Save-Settings($s) { ($s | ConvertTo-Json -Depth 5) | Set-Content -Path $SettingsPath -Encoding UTF8 }

# ===========================================================================
# SCANNER - finds installed games. Runs on a background runspace.
# ===========================================================================
$Scanner = {
    param($S, $Sync, $DataDir)
    $ErrorActionPreference = 'SilentlyContinue'
    function Log($m) { if ($Sync) { $Sync.Queue.Enqueue(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) } }
    function Norm($n) { ("$n".ToLower() -replace '[^a-z0-9]', '') }

    $games = New-Object System.Collections.ArrayList
    $seen  = @{}

    # exe names that are never "the game"
    $ExcludeExe = '^(unins.*|.*setup.*|vc_?redist.*|vcredist.*|dxwebsetup|dotnet.*|.*crash.*|.*report.*|.*prereq.*|.*install.*|.*updater?|.*helper|.*cefsubprocess.*|.*bootstrap.*|.*anticheat.*|beservice.*|.*benchmark.*|.*launcher.*|elevate|.*browser|.*editor.*|.*redist.*|.*webview.*|.*service)$'

    function Get-Exes($dir) {
        $all = @(Get-ChildItem -LiteralPath $dir -Recurse -Depth 6 -File -Filter *.exe -ErrorAction SilentlyContinue)
        $good = @($all | Where-Object { $_.BaseName -notmatch $ExcludeExe })
        if ($good.Count -eq 0) { $good = $all }      # only launchers/odd names here - better than nothing
        $good | Sort-Object Length -Descending | Select-Object -First 8
    }

    function Add-Game($id, $name, $store, $install, $launch, $exeFiles, $art) {
        if (-not $name -or -not $install -or -not (Test-Path -LiteralPath $install)) { return }
        $key = $install.ToLower().TrimEnd('\')
        if ($seen.ContainsKey($key)) { return }
        if (-not $exeFiles) { $exeFiles = Get-Exes $install }
        $exeFiles = @($exeFiles)
        if ($exeFiles.Count -eq 0) { return }
        $seen[$key] = $true
        [void]$games.Add([ordered]@{
            id = $id; name = $name; store = $store; install = $install; launch = $launch
            exes = @($exeFiles | ForEach-Object { $_.BaseName.ToLower() } | Select-Object -Unique)
            icon = $exeFiles[0].FullName; art = $art; discordId = $null; matched = $false
        })
    }

    # ---- Steam
    try {
        $steam = ("$((Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath)") -replace '/', '\'
        if ($steam -and (Test-Path $steam)) {
            $libs = @($steam)
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
            }
            foreach ($lib in ($libs | Select-Object -Unique)) {
                foreach ($acf in Get-ChildItem (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf') {
                    $t = Get-Content $acf.FullName -Raw
                    $appid = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
                    $name  = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value
                    $dir   = [regex]::Match($t, '"installdir"\s+"([^"]+)"').Groups[1].Value
                    if (-not $appid -or -not $name -or $name -match 'Steamworks|Proton|Steam Linux|Redistributable|Runtime|Wallpaper Engine|Dedicated Server|SDK') { continue }
                    $art = $null
                    $cache = Join-Path $steam "appcache\librarycache\$appid"
                    foreach ($f in 'header.jpg', 'library_600x900.jpg') { if (-not $art -and (Test-Path (Join-Path $cache $f))) { $art = Join-Path $cache $f } }
                    Add-Game "steam:$appid" $name 'Steam' (Join-Path $lib "steamapps\common\$dir") "steam://rungameid/$appid" $null $art
                }
            }
        }
    } catch { Log "Steam scan problem: $($_.Exception.Message)" }

    # ---- Epic Games
    try {
        foreach ($f in Get-ChildItem 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests' -Filter *.item) {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not $j.DisplayName -or -not $j.InstallLocation -or "$($j.LaunchExecutable)" -match 'Editor' -or $j.DisplayName -match 'Editor') { continue }
            Add-Game "epic:$($j.AppName)" $j.DisplayName 'Epic' $j.InstallLocation "com.epicgames.launcher://apps/$($j.AppName)?action=launch&silent=true" $null $null
        }
    } catch { Log "Epic scan problem: $($_.Exception.Message)" }

    # ---- GOG
    try {
        foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games') {
            $p = Get-ItemProperty $k.PSPath
            if ($p.gameName -and $p.path) {
                $exe = if ($p.exe) { $p.exe } else { $null }
                Add-Game "gog:$($k.PSChildName)" $p.gameName 'GOG' $p.path $exe $null $null
            }
        }
    } catch {}

    # ---- launcher folders (Riot, HoYoPlay, Xbox, EA, Ubisoft, ...) + your own folders
    $groupNames = 'epic', 'hoyoplay', 'rockstar', 'steam', 'riot games', 'origin', 'ea', 'ubisoft', 'xboxgames', 'gog galaxy', 'games', 'epic games', 'battle.net'
    $skipNames  = 'steamlibrary', 'steamapps', 'launcher', 'gamesave', 'directxredist', 'gameinputredist', 'riot client', 'common', 'downloading', 'temp'
    $roots = @('C:\Riot Games', 'C:\XboxGames', 'C:\Program Files\EA Games', 'C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games', 'C:\Program Files\Epic Games')
    foreach ($d in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        $roots += (Join-Path $d.Name 'Games')
    }
    $roots += @($S.extra_folders)
    $roots = $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    function Scan-Folder($dir, $depth) {
        foreach ($c in Get-ChildItem -LiteralPath $dir -Directory) {
            $n = $c.Name.ToLower()
            if ($skipNames -contains $n) { continue }
            if (($groupNames -contains $n) -and $depth -lt 2) { Scan-Folder $c.FullName ($depth + 1); continue }
            $exes = Get-Exes $c.FullName
            if (-not $exes) { continue }
            $name = $c.Name -replace '\s+[Gg]ames?$', ''
            try { $pn = $exes[0].VersionInfo.ProductName; if ($pn -and $pn.Length -gt 2 -and $pn -notmatch 'Unreal|Unity') { $name = $pn } } catch {}
            Add-Game "folder:$($c.FullName.ToLower())" $name 'Folder' $c.FullName $exes[0].FullName $exes $null
        }
    }
    foreach ($r in $roots) { Scan-Folder $r 0 }

    # ---- games added by hand
    foreach ($cg in @($S.custom_games)) {
        if ($cg.exe -and (Test-Path -LiteralPath $cg.exe)) {
            $fi = Get-Item -LiteralPath $cg.exe
            Add-Game "custom:$($fi.FullName.ToLower())" $cg.name 'Added' $fi.DirectoryName $fi.FullName @($fi) $null
        }
    }

    # ---- an exe shared by several games (e.g. a bundled browser helper) can't identify any one of them
    $exeCount = @{}
    foreach ($g in $games) { foreach ($e in $g.exes) { $exeCount[$e] = 1 + [int]$exeCount[$e] } }
    foreach ($g in $games) {
        $unique = @($g.exes | Where-Object { $exeCount[$_] -eq 1 })
        if ($unique.Count -gt 0) { $g.exes = $unique }
    }

    # ---- match every game to its official Discord application (public "detectable games" list)
    try {
        $cache = Join-Path $DataDir 'detectable.json'
        if (-not (Test-Path $cache) -or ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -gt 7) {
            Log "Downloading Discord's list of known games..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = 'RichPresence (personal use)'
            $wc.Encoding = [Text.Encoding]::UTF8
            $wc.DownloadString('https://discord.com/api/v9/applications/detectable') | Set-Content $cache -Encoding UTF8
        }
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $apps = $ser.DeserializeObject((Get-Content $cache -Raw -Encoding UTF8))
        $idx = @{}; $byName = @{}
        foreach ($a in $apps) {
            $an = Norm $a['name']
            if ($an -and -not $byName.ContainsKey($an)) { $byName[$an] = $a }
            foreach ($e in $a['executables']) {
                if ($e['os'] -ne 'win32' -or $e['is_launcher']) { continue }
                $b = ("$($e['name'])" -split '[\\/]')[-1].ToLower() -replace '^>', '' -replace '\.exe$', ''
                if (-not $b) { continue }
                if (-not $idx.ContainsKey($b)) { $idx[$b] = New-Object System.Collections.ArrayList }
                [void]$idx[$b].Add($a)
            }
        }
        $generic = 'game', 'launcher', 'client', 'main', 'start', 'play', 'app', 'shipping', 'win64', 'editor', 'server'
        foreach ($g in $games) {
            $gn = Norm $g.name
            $score = @{}; $appById = @{}
            foreach ($e in $g.exes) {
                if (-not $idx.ContainsKey($e)) { continue }
                foreach ($a in $idx[$e]) {
                    $id = "$($a['id'])"; $an = Norm $a['name']; $appById[$id] = $a
                    $pts = 1
                    if ($an -eq $gn) { $pts += 10 }
                    elseif ($gn.Length -ge 4 -and $an.Length -ge 4 -and ($an.Contains($gn) -or $gn.Contains($an))) { $pts += 5 }
                    elseif ($e.Length -ge 8 -and ($generic -notcontains $e)) { $pts += 3 }
                    $score[$id] += $pts
                }
            }
            $bestId = $null; $bestPts = 0
            foreach ($k in $score.Keys) { if ($score[$k] -gt $bestPts) { $bestPts = $score[$k]; $bestId = $k } }
            if ($bestId -and $bestPts -ge 4) {
                $g.discordId = $bestId; $g.matched = $true; $hit = $appById[$bestId]
                # trust Discord's own executable list for this game over our guesses
                $official = @()
                foreach ($e in $g.exes) {
                    if (-not $idx.ContainsKey($e)) { continue }
                    foreach ($a in $idx[$e]) { if ("$($a['id'])" -eq $bestId) { $official += $e; break } }
                }
                if ($official.Count -gt 0) { $g.exes = $official }
            }
            elseif ($byName.ContainsKey($gn)) { $hit = $byName[$gn]; $g.discordId = "$($hit['id'])"; $g.matched = $true }
            else { $hit = $null }
            # tidy folder-derived names using Discord's official name
            if ($hit -and $g.store -in 'Folder', 'Added') { $g.name = "$($hit['name'])" }
        }
    } catch { Log "Couldn't match games to Discord ($($_.Exception.Message)). They will still be listed." }

    $sorted = @($games | Sort-Object { $_.name })
    ($sorted | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $DataDir 'library.json') -Encoding UTF8
    Log ("Found {0} games ({1} matched to Discord)." -f $sorted.Count, @($sorted | Where-Object { $_.matched }).Count)
    if ($Sync) { $Sync.ScanDone = $true }
    return $sorted
}

# ===========================================================================
# ENGINE - runs on a background runspace. Talks to Discord and watches for games.
# It never touches the UI; it only writes to $Sync.
# ===========================================================================
$Engine = {
    param($S, $Sync)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    function Log($m) { $Sync.Queue.Enqueue(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) }
    function Nap($sec) {
        $end = [datetime]::UtcNow.AddSeconds($sec)
        while (-not $Sync.Stop -and [datetime]::UtcNow -lt $end) { Start-Sleep -Milliseconds 200 }
    }

    $GameId     = "$($S.game_client_id)".Trim()
    $MusicId    = "$($S.music_client_id)".Trim()
    $AppId      = "$($S.app_client_id)".Trim()
    $GenshinUid = "$($S.genshin_uid)".Trim()
    $ShowMusic  = [bool]$S.show_music
    $ShowLyrics = [bool]$S.show_lyrics
    $ShowArt    = [bool]$S.show_album_art
    $ShowApps   = [bool]$S.show_current_app
    $OfficialToDiscord = [bool]$S.official_to_discord
    $OfficialDelayMin  = [double]$(if ($null -ne $S.official_delay_minutes) { $S.official_delay_minutes } else { 2 })
    foreach ($pair in @(@('game', $GameId), @('music', $MusicId), @('app', $AppId))) {
        if ($pair[1] -notmatch '^\d{17,20}$') { Log "The $($pair[0]) Discord app ID isn't valid (17-20 digits). Fix it under Music & Apps > Advanced."; return }
    }

    # ---------------------------------------------------------------- Apple Music (Windows media API)
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    function Await($op, $resultType) {
        $t = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
        $t.Wait(-1) | Out-Null
        $t.Result
    }
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
    $SmtcType  = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
    $PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]

    function Get-AppleMusicSession {
        $mgr = Await ($SmtcType::RequestAsync()) $SmtcType
        $apple = @($mgr.GetSessions()) | Where-Object { $_.SourceAppUserModelId -match 'AppleMusic|AppleInc' } | Select-Object -First 1
        if (-not $apple) {
            $cur = $mgr.GetCurrentSession()
            if ($cur -and $cur.SourceAppUserModelId -match 'AppleMusic|AppleInc') { $apple = $cur }
        }
        return $apple
    }

    $ArtCache = @{}; $LyricsCache = @{}
    function Get-AlbumArtUrl($artist, $title, $album) {
        if (-not $ShowArt) { return $null }
        $key = "$artist|$album|$title"
        if ($ArtCache.ContainsKey($key)) { return $ArtCache[$key] }
        $url = $null
        try {
            $term = [uri]::EscapeDataString("$artist $album $title")
            $resp = Invoke-RestMethod -Uri "https://itunes.apple.com/search?term=$term&entity=song&limit=1" -TimeoutSec 8
            if ($resp.resultCount -ge 1 -and $resp.results[0].artworkUrl100) { $url = $resp.results[0].artworkUrl100 -replace '100x100bb', '512x512bb' }
        } catch {}
        $ArtCache[$key] = $url
        return $url
    }
    function Get-SyncedLyrics($artist, $title, $album, $durationSec) {
        if (-not $ShowLyrics) { return $null }
        $key = "$artist|$title|$album"
        if ($LyricsCache.ContainsKey($key)) { return $LyricsCache[$key] }
        $parsed = $null
        try {
            $q = "artist_name=$([uri]::EscapeDataString($artist))&track_name=$([uri]::EscapeDataString($title))"
            if ($album)       { $q += "&album_name=$([uri]::EscapeDataString($album))" }
            if ($durationSec) { $q += "&duration=$([int]$durationSec)" }
            $resp = Invoke-RestMethod -Uri "https://lrclib.net/api/get?$q" -Headers @{ 'User-Agent' = 'RichPresence (personal use)' } -TimeoutSec 8
            if ($resp.syncedLyrics) {
                $lines = @()
                foreach ($line in ($resp.syncedLyrics -split "`n")) {
                    $m = [regex]::Match($line, '^\[(\d+):(\d+(?:\.\d+)?)\](.*)$')
                    if ($m.Success) { $lines += [pscustomobject]@{ t = [int]$m.Groups[1].Value * 60 + [double]$m.Groups[2].Value; text = $m.Groups[3].Value.Trim() } }
                }
                if ($lines.Count) { $parsed = $lines | Sort-Object t }
            }
        } catch {}
        $LyricsCache[$key] = $parsed
        return $parsed
    }
    function Get-CurrentLyricLine($lyrics, $posSec) {
        if (-not $lyrics) { return $null }
        $line = $null
        foreach ($l in $lyrics) { if ($l.t -le ($posSec + 0.3)) { $line = $l.text } else { break } }
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        if ($line.Length -gt 128) { $line = $line.Substring(0, 125) + '...' }
        return $line
    }

    # ---------------------------------------------------------------- Foreground app (Win32)
    if (-not ('RPFG' -as [type])) {
        Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class RPFG {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    public static string Title(IntPtr h) {
        int len = GetWindowTextLength(h);
        if (len <= 0) return "";
        var sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@
    }
    $Ignore = @('discord', 'lockapp', 'searchhost', 'shellexperiencehost', 'startmenuexperiencehost', 'textinputhost',
                'systemsettings', 'applicationframehost', 'dwm', 'sihost', 'richpresence')
    $Friendly = @{
        'code' = 'Visual Studio Code'; 'devenv' = 'Visual Studio'; 'powershell' = 'PowerShell'; 'pwsh' = 'PowerShell'
        'windowsterminal' = 'Windows Terminal'; 'cmd' = 'Command Prompt'; 'chrome' = 'Google Chrome'; 'msedge' = 'Microsoft Edge'
        'firefox' = 'Firefox'; 'explorer' = 'File Explorer'; 'notepad' = 'Notepad'; 'spotify' = 'Spotify'
        'applemusic' = 'Apple Music'; 'steam' = 'Steam'; 'obs64' = 'OBS Studio'; 'photoshop' = 'Photoshop'
        'blender' = 'Blender'; 'slack' = 'Slack'; 'obsidian' = 'Obsidian'; 'winword' = 'Word'; 'excel' = 'Excel'
    }
    $IconDomain = @{
        'devenv' = 'visualstudio.microsoft.com'; 'code' = 'code.visualstudio.com'; 'chrome' = 'google.com'
        'msedge' = 'microsoft.com'; 'firefox' = 'mozilla.org'; 'spotify' = 'spotify.com'; 'applemusic' = 'music.apple.com'
        'steam' = 'store.steampowered.com'; 'slack' = 'slack.com'; 'obsidian' = 'obsidian.md'; 'obs64' = 'obsproject.com'
        'photoshop' = 'adobe.com'; 'blender' = 'blender.org'; 'winword' = 'microsoft.com'; 'excel' = 'microsoft.com'
    }
    $script:GameExeSet = @{}
    function Get-Foreground {
        $h = [RPFG]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $null }
        $procId = 0; [RPFG]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
        if ($procId -le 0) { return $null }
        try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { return $null }
        $name = $p.ProcessName.ToLower()
        if ($Ignore -contains $name -or $script:GameExeSet.ContainsKey($name)) { return $null }
        $label = $Friendly[$name]
        if (-not $label) { try { $label = $p.MainModule.FileVersionInfo.FileDescription } catch {} }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $p.ProcessName }
        $icon = if ($IconDomain.ContainsKey($name)) { "https://www.google.com/s2/favicons?sz=128&domain=$($IconDomain[$name])" } else { $null }
        [pscustomobject]@{ Proc = $name; Label = "$label"; Title = "$([RPFG]::Title($h))"; Icon = $icon }
    }

    # ---------------------------------------------------------------- Genshin extras (Enka.Network public profile)
    $script:GenshinInfo = $null; $script:GenshinFetchedAt = [datetime]::MinValue
    function Get-GenshinInfo {
        if ($GenshinUid -notmatch '^\d{9,10}$') { return $null }
        if ($script:GenshinInfo -and ([datetime]::UtcNow - $script:GenshinFetchedAt).TotalMinutes -lt 10) { return $script:GenshinInfo }
        $script:GenshinFetchedAt = [datetime]::UtcNow
        try {
            $resp = Invoke-RestMethod -Uri "https://enka.network/api/uid/${GenshinUid}?info" -Headers @{ 'User-Agent' = 'RichPresence (personal use)' } -TimeoutSec 10
            $pi = $resp.playerInfo
            if ($pi) {
                $script:GenshinInfo = [pscustomobject]@{ Nickname = "$($pi.nickname)"; Level = [int]$pi.level; WorldLevel = [int]$pi.worldLevel }
                Log ("Genshin profile: {0}  AR {1}  WL {2}" -f $script:GenshinInfo.Nickname, $script:GenshinInfo.Level, $script:GenshinInfo.WorldLevel)
            }
        } catch { Log "Couldn't load your Genshin profile (is Character Showcase public in-game?)" }
        return $script:GenshinInfo
    }

    # ---------------------------------------------------------------- game activity
    function Get-GameStartMs($g, $proc) {
        $ms = $null
        try { $ms = ([DateTimeOffset]$proc.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() } catch {}
        if (-not $ms) {
            if (-not $script:FirstSeen.ContainsKey($g.id)) { $script:FirstSeen[$g.id] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
            $ms = $script:FirstSeen[$g.id]
        }
        return $ms
    }
    $script:FirstSeen = @{}
    function New-GameActivity($g, $proc) {
        $a = @{ type = 0; name = $g.name; timestamps = @{ start = (Get-GameStartMs $g $proc) } }
        if ($g.exes -contains 'genshinimpact' -or $g.exes -contains 'yuanshen') {
            $gi = Get-GenshinInfo
            if ($gi) {
                $a.details = "$($gi.Nickname) - AR $($gi.Level)"
                $a.state   = "UID $GenshinUid - WL $($gi.WorldLevel)"
                $a.assets  = @{ large_image = 'https://www.google.com/s2/favicons?sz=128&domain=genshin.hoyoverse.com'; large_text = 'Genshin Impact' }
            }
        }
        return $a
    }

    # ---------------------------------------------------------------- Discord IPC (one connection per Discord app id)
    function New-Conn($clientId, $name) { @{ Pipe = $null; ClientId = $clientId; Name = $name; Id = $null; SentUtc = [datetime]::MinValue } }
    function Close-Discord($c) { try { if ($c.Pipe) { $c.Pipe.Dispose() } } catch {}; $c.Pipe = $null }
    function Send-Frame($c, [int]$op, [string]$json) {
        $data = [Text.Encoding]::UTF8.GetBytes($json)
        $header = New-Object byte[] 8
        [BitConverter]::GetBytes([int32]$op).CopyTo($header, 0)
        [BitConverter]::GetBytes([int32]$data.Length).CopyTo($header, 4)
        $c.Pipe.Write($header, 0, 8); $c.Pipe.Write($data, 0, $data.Length); $c.Pipe.Flush()
    }
    function Read-Frame($c) {
        try {
            $h = New-Object byte[] 8
            if ($c.Pipe.Read($h, 0, 8) -lt 8) { return $null }
            $len = [BitConverter]::ToInt32($h, 4)
            if ($len -le 0) { return '' }
            $b = New-Object byte[] $len; $g = 0
            while ($g -lt $len) { $g += $c.Pipe.Read($b, $g, $len - $g) }
            [Text.Encoding]::UTF8.GetString($b)
        } catch { $null }
    }
    function Connect-Discord($c) {
        if ($c.Pipe -and $c.Pipe.IsConnected) { return $true }
        foreach ($i in 0..9) {
            $p = $null
            try {
                $p = New-Object System.IO.Pipes.NamedPipeClientStream('.', "discord-ipc-$i", 'InOut', 'Asynchronous')
                $p.Connect(1000)
                $c.Pipe = $p
                Send-Frame $c 0 (@{ v = 1; client_id = $c.ClientId } | ConvertTo-Json -Compress)
                Read-Frame $c | Out-Null
                return $true
            } catch { if ($p) { $p.Dispose() }; $c.Pipe = $null }
        }
        return $false
    }
    function Set-Activity($c, $activity) {
        Send-Frame $c 1 (@{ cmd = 'SET_ACTIVITY'; nonce = [guid]::NewGuid().ToString(); args = @{ pid = $PID; activity = $activity } } | ConvertTo-Json -Depth 8 -Compress)
        Read-Frame $c | Out-Null
    }
    function Clear-Activity($c) {
        Send-Frame $c 1 (@{ cmd = 'SET_ACTIVITY'; nonce = [guid]::NewGuid().ToString(); args = @{ pid = $PID } } | ConvertTo-Json -Depth 8 -Compress)
        Read-Frame $c | Out-Null
    }

    $ConnMusic = New-Conn $MusicId 'music'
    $ConnApp   = New-Conn $AppId   'app'
    $GameConns = @{}     # discord app id -> connection (one card per game)

    function Update-GameCards($running) {
        $wanted = @{}
        foreach ($r in $running) {
            # Discord detects its official games itself: give it a head start so the session counts for
            # Recent Activity and streaks, then show our own card (with extras like the Genshin stats)
            if ($OfficialToDiscord -and $r.G.discordId) {
                $startMs = Get-GameStartMs $r.G $r.P
                if (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startMs) -lt ($OfficialDelayMin * 60000)) { continue }
            }
            # official Discord app if we know one, otherwise the shared generic game app
            $cid = if ($r.G.discordId) { "$($r.G.discordId)" } else { $GameId }
            if (-not $wanted.ContainsKey($cid)) { $wanted[$cid] = $r }
        }
        foreach ($id in @($wanted.Keys)) {
            try {
                if (-not $GameConns.ContainsKey($id)) { $GameConns[$id] = New-Conn $id 'game' }
                $c = $GameConns[$id]
                if (-not (Connect-Discord $c)) { continue }
                $r = $wanted[$id]
                $sig = "$($r.G.id)|$($script:GenshinInfo.Level)|$($script:GenshinInfo.WorldLevel)"
                if (($c.Id -ne $sig) -or (([datetime]::UtcNow - $c.SentUtc).TotalSeconds -ge 20)) {
                    Set-Activity $c (New-GameActivity $r.G $r.P)
                    if ($c.Id -ne $sig) { Log "Playing: $($r.G.name)" }
                    $c.Id = $sig; $c.SentUtc = [datetime]::UtcNow
                }
            } catch { Log "Game card error: $($_.Exception.Message)"; Close-Discord $GameConns[$id]; $GameConns.Remove($id) }
        }
        foreach ($id in @($GameConns.Keys)) {
            if (-not $wanted.ContainsKey($id)) { Close-Discord $GameConns[$id]; $GameConns.Remove($id); Log "Game closed - card removed" }
        }
    }

    # ---------------------------------------------------------------- main loop
    $FALLBACK_IMAGE   = 'https://upload.wikimedia.org/wikipedia/commons/thumb/5/5f/Apple_Music_icon.svg/240px-Apple_Music_icon.svg.png'
    $GENERIC_APP_ICON = 'https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Windows_logo_-_2021.svg/240px-Windows_logo_-_2021.svg.png'
    $lastLyricLine = $null; $appStartMs = $null; $appPendProc = $null; $appPendSince = [datetime]::MinValue
    $lastValidAppUtc = $null; $sawWatch = $false; $watchGoneSince = $null; $watchStarted = [datetime]::UtcNow; $lastWatch = $null

    # rate-capped SET_ACTIVITY for one card (each connection keeps its own state)
    function Push-Card($c, $activity, $id, $critical) {
        $since = ([datetime]::UtcNow - $c.SentUtc).TotalSeconds
        if (-not $critical -and $since -lt 5) { return $false }
        if ($critical -and $since -lt 2) { Start-Sleep -Milliseconds 800 }
        Set-Activity $c $activity
        $c.SentUtc = [datetime]::UtcNow; $c.Id = $id
        return $true
    }
    function Clear-Card($c) {
        if ($c.Pipe -and $c.Id) { try { Clear-Activity $c } catch {} }
        $c.Id = $null
    }
    function Test-DiscordRunning { [bool]([System.IO.Directory]::GetFiles('\\.\pipe\') -match 'discord-ipc-') }

    Log "Presence started."
    while (-not $Sync.Stop) {
        try {
            if (-not (Test-DiscordRunning)) {
                $Sync.Status = 'Waiting for Discord...'
                Close-Discord $ConnMusic; Close-Discord $ConnApp
                foreach ($k in @($GameConns.Keys)) { Close-Discord $GameConns[$k] }; $GameConns = @{}
                Nap 8; continue
            }

            # ---- which library games are running?
            $procs = @{}
            foreach ($p in Get-Process) { $procs[$p.ProcessName.ToLower()] = $p }
            $script:GameExeSet = @{}
            $running = @()
            foreach ($g in @($Sync.Games)) {
                foreach ($e in @($g.exes)) { $script:GameExeSet["$e"] = $true }
                if (-not $g.enabled) { continue }
                foreach ($e in @($g.exes)) {
                    if ($procs.ContainsKey("$e")) { $running += [pscustomobject]@{ G = $g; P = $procs["$e"] }; break }
                }
            }
            $Sync.RunningIds = @($running | ForEach-Object { $_.G.id })

            # "quit when the game closes" - only for the game we launched
            if ($Sync.WatchId) {
                if ($lastWatch -ne $Sync.WatchId) { $lastWatch = $Sync.WatchId; $sawWatch = $false; $watchGoneSince = $null; $watchStarted = [datetime]::UtcNow }
                if ($Sync.RunningIds -contains $Sync.WatchId) { $sawWatch = $true; $watchGoneSince = $null }
                elseif ($sawWatch) {
                    if (-not $watchGoneSince) { $watchGoneSince = [datetime]::UtcNow }
                    elseif (([datetime]::UtcNow - $watchGoneSince).TotalSeconds -gt 8) { $Sync.GameExited = $true; $Sync.WatchId = $null }
                }
                elseif (([datetime]::UtcNow - $watchStarted).TotalMinutes -gt 10) { $Sync.WatchId = $null }
            }

            # ================= CARD 1: the game =================
            Update-GameCards $running

            # ================= CARD 2: Apple Music =================
            $musicActive = $false
            if ($ShowMusic) {
                $session = Get-AppleMusicSession
                $status = $null; $title = $null; $artist = $null; $album = $null; $position = 0; $duration = 0
                if ($session) {
                    $status = "$($session.GetPlaybackInfo().PlaybackStatus)"
                    $props  = Await ($session.TryGetMediaPropertiesAsync()) $PropsType
                    $title  = "$($props.Title)".Trim(); $artist = "$($props.Artist)".Trim(); $album = "$($props.AlbumTitle)".Trim()
                    if ([string]::IsNullOrWhiteSpace($album) -and $artist) {
                        $dashes = ([char]0x2012, [char]0x2013, [char]0x2014, [char]0x2015) -join '|'
                        $m = [regex]::Match(($artist -replace $dashes, '-'), '^(.+?)\s+-\s+(.+)$')
                        if ($m.Success) { $artist = $m.Groups[1].Value.Trim(); $album = $m.Groups[2].Value.Trim() }
                    }
                    $tl = $session.GetTimelineProperties()
                    $duration = ($tl.EndTime.TotalSeconds - $tl.StartTime.TotalSeconds)
                    $position = ($tl.Position.TotalSeconds - $tl.StartTime.TotalSeconds)
                    if ($status -eq 'Playing' -and $tl.LastUpdatedTime.Year -gt 1) { $position += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds }
                    if ($duration -gt 0) { $position = [math]::Max(0, [math]::Min($position, $duration)) }
                }
                $musicActive = [bool]($status -eq 'Playing' -and $title)
            }
            if ($musicActive -and (Connect-Discord $ConnMusic)) {
                $lyrics  = Get-SyncedLyrics $artist $title $album $duration
                $curLine = Get-CurrentLyricLine $lyrics $position
                $id = "music|$artist|$title|$album"
                $trackChanged = ($ConnMusic.Id -ne $id)
                $lyricChanged = ($ShowLyrics -and $curLine -and $curLine -ne $lastLyricLine)
                if ($trackChanged -or $lyricChanged -or (([datetime]::UtcNow - $ConnMusic.SentUtc).TotalSeconds -ge 15)) {
                    $art = Get-AlbumArtUrl $artist $title $album
                    $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]([math]::Round($position * 1000))
                    $activity = @{
                        type = 2; details = $title
                        state = if ($ShowLyrics -and $curLine) { $curLine } else { "by $artist" }
                        assets = @{ large_image = $(if ($art) { $art } else { $FALLBACK_IMAGE }); large_text = $(if ($album) { "$title - $album" } else { $title }) }
                        timestamps = @{ start = $startMs }
                    }
                    if ($artist) { $activity.name = $artist }
                    if ($duration -gt 0) { $activity.timestamps.end = $startMs + [int64]([math]::Round($duration * 1000)) }
                    if (Push-Card $ConnMusic $activity $id $trackChanged) {
                        if ($trackChanged) { Log "Music: $artist - $title"; $lastLyricLine = $null }
                        if ($lyricChanged) { $lastLyricLine = $curLine }
                    }
                }
            } elseif (-not $musicActive) {
                Clear-Card $ConnMusic
                Close-Discord $ConnMusic
            }

            # ================= CARD 3: the app you're using =================
            $appShown = $false
            if ($ShowApps -and (Connect-Discord $ConnApp)) {
                $fg = Get-Foreground
                if ($fg) {
                    $lastValidAppUtc = [datetime]::UtcNow
                    if ($fg.Proc -ne $appPendProc) { $appPendProc = $fg.Proc; $appPendSince = [datetime]::UtcNow }
                    $settled = ([datetime]::UtcNow - $appPendSince).TotalSeconds
                    $id = "app|$($fg.Label)"
                    $isNew = ($ConnApp.Id -ne $id) -and ($settled -ge 3)
                    if ($isNew -or ($ConnApp.Id -eq $id) -or (([datetime]::UtcNow - $ConnApp.SentUtc).TotalSeconds -ge 20)) {
                        if ($isNew -or -not $appStartMs) { $appStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                        $detail = $fg.Title; if ($detail.Length -gt 128) { $detail = $detail.Substring(0, 125) + '...' }
                        $activity = @{ type = 0; name = $fg.Label; timestamps = @{ start = $appStartMs } }
                        if ($detail -and $detail -ne $fg.Label) { $activity.details = $detail }
                        $activity.assets = @{ large_image = $(if ($fg.Icon) { $fg.Icon } else { $GENERIC_APP_ICON }); large_text = $fg.Label }
                        if (Push-Card $ConnApp $activity $id $isNew) { if ($isNew) { Log "App: $($fg.Label)" } }
                    }
                    $appShown = $true; $Sync.AppLabel = $fg.Label
                }
                # ignored window (Discord itself, or the game): keep the last app for a few minutes
                elseif ($ConnApp.Id -and $lastValidAppUtc -and (([datetime]::UtcNow - $lastValidAppUtc).TotalSeconds -lt 300)) { $appShown = $true }
                if (-not $appShown) { Clear-Card $ConnApp }
            } elseif (-not $ShowApps) {
                Clear-Card $ConnApp; Close-Discord $ConnApp
            }

            $parts = @()
            if ($running.Count) { $parts += "Playing $($running[0].G.name)" }
            if ($musicActive)   { $parts += "Listening: $title" }
            if ($appShown -and -not $running.Count) { $parts += "App: $($Sync.AppLabel)" }
            $Sync.Status = if ($parts.Count) { $parts -join '  |  ' } else { 'Watching for games' }
            Nap 3
        }
        catch {
            Log "Error: $($_.Exception.Message)"
            Close-Discord $ConnMusic; Close-Discord $ConnApp
            foreach ($k in @($GameConns.Keys)) { Close-Discord $GameConns[$k] }; $GameConns = @{}
            Nap 5
        }
    }

    # stopped: remove our cards
    Clear-Card $ConnMusic; Clear-Card $ConnApp
    Close-Discord $ConnMusic; Close-Discord $ConnApp
    foreach ($k in @($GameConns.Keys)) { Close-Discord $GameConns[$k] }
    Log "Presence stopped."
}

# ===========================================================================
# UPDATER - runs on a background runspace. Looks at the latest GitHub release and, if it's newer,
# downloads RichPresence.exe and checks it against the SHA-256 GitHub publishes for it.
# ===========================================================================
$Updater = {
    param($Sync, $Current, $DataDir)
    $ErrorActionPreference = 'Stop'
    function Log($m) { $Sync.Queue.Enqueue(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/noice912/RichPresence/releases/latest' -Headers @{ 'User-Agent' = 'RichPresence updater' } -TimeoutSec 20
        $latest = "$($rel.tag_name)".TrimStart('v')
        $Sync.LatestVersion = $latest
        if ([version]$latest -le [version]$Current) { $Sync.UpdateState = 'current'; return }
        $asset = @($rel.assets) | Where-Object { $_.name -eq 'RichPresence.exe' } | Select-Object -First 1
        if (-not $asset) { $Sync.UpdateState = 'current'; return }
        $dir = Join-Path $DataDir 'update'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir "RichPresence-$latest.exe"
        Log "Downloading update $latest..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'RichPresence updater' } -TimeoutSec 120
        $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
        $want = "$($asset.digest)" -replace '^sha256:', ''
        if (-not $want) { Remove-Item $file -Force; Log "Update $latest has no published checksum, so it wasn't installed."; $Sync.UpdateState = 'failed'; return }
        if ($hash -ne $want.ToLower()) { Remove-Item $file -Force; Log "Update $latest didn't match its checksum and was deleted."; $Sync.UpdateState = 'failed'; return }
        $Sync.UpdateFile = $file
        $Sync.UpdateState = 'ready'
        Log "Update $latest downloaded and verified."
    } catch {
        $Sync.UpdateState = 'failed'
        Log "Couldn't check for updates: $($_.Exception.Message)"
    }
}

# ===========================================================================
# Runner helpers
# ===========================================================================
function New-Sync {
    [hashtable]::Synchronized(@{
        Stop = $false; Queue = (New-Object System.Collections.Concurrent.ConcurrentQueue[string])
        Status = 'Stopped'; Games = @(); RunningIds = @(); WatchId = $null; GameExited = $false; ScanDone = $false; AppLabel = ''
        UpdateState = ''; UpdateFile = $null; LatestVersion = ''
    })
}
function Start-Block($block, $arguments) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($block.ToString())
    foreach ($a in $arguments) { [void]$ps.AddArgument($a) }
    [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}
function Stop-Block($job, $sync, $wait) {
    if (-not $job) { return }
    if ($sync) { $sync.Stop = $true }
    if ($wait) { [void]$job.Handle.AsyncWaitHandle.WaitOne($wait) }
    try { $job.PS.Dispose(); $job.RS.Dispose() } catch {}
}
function Read-Library {
    if (-not (Test-Path $LibraryPath)) { return @() }
    try {
        $j = Get-Content $LibraryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($j | ForEach-Object { $_ })     # Windows PowerShell 5.1 returns the JSON array as one object - unwrap it
    } catch { return @() }
}
function New-EngineGames($library, $settings) {
    @($library | ForEach-Object {
        @{ id = $_.id; name = $_.name; exes = @($_.exes); discordId = $(if ($_.discordId) { "$($_.discordId)" } else { $null })
           enabled = (@($settings.disabled_games) -notcontains $_.id) }
    })
}

if ($ScanOnly) {
    $s = Load-Settings
    $res = & $Scanner $s $null $DataDir
    $res | ForEach-Object { "{0,-34} {1,-7} discord={2,-20} exes={3}" -f $_.name, $_.store, $(if ($_.discordId) { $_.discordId } else { '-' }), (($_.exes | Select-Object -First 3) -join ',') }
    exit
}

if ($Headless) {
    $settings = Add-BuiltInIds (Load-Settings)
    $sync = New-Sync
    $sync.Games = New-EngineGames (Read-Library) $settings
    $job = Start-Block $Engine @($settings, $sync)
    Write-Host "RichPresence (headless) - Ctrl+C to stop"
    try {
        while ($true) {
            $line = $null
            while ($sync.Queue.TryDequeue([ref]$line)) { Write-Host $line }
            if ($job.Handle.IsCompleted) { break }
            Start-Sleep -Milliseconds 300
        }
    } finally { Stop-Block $job $sync 8000 }
    exit
}

# ===========================================================================
# Window
# ===========================================================================
$mutex = New-Object System.Threading.Mutex($false, 'Local\RichPresenceLauncher')
if (-not $mutex.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show('RichPresence is already running - check your system tray.', 'RichPresence') | Out-Null
    exit
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$Settings = Load-Settings
$Sync     = New-Sync
$script:Job = $null; $script:ScanJob = $null
$script:Library = @(Read-Library)
$script:Tiles = @{}
$script:reallyQuit = $false
$script:PendingPlay = $Play

$SelfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$IsExe    = $SelfPath -like '*.exe' -and $SelfPath -notmatch 'powershell|pwsh'

# ---- look & feel
function C($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$cBg = C '#14161b'; $cSide = C '#0f1115'; $cCard = C '#1f232b'; $cCardHi = C '#272c36'; $cText = C '#e8eaf0'; $cDim = C '#8b91a1'
$cAccent = C '#5865f2'; $cGreen = C '#3ba55d'
$fUi = New-Object System.Drawing.Font('Segoe UI', 9)
$fBold = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$fSmall = New-Object System.Drawing.Font('Segoe UI', 8)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'RichPresence'
$form.Font = $fUi; $form.BackColor = $cBg; $form.ForeColor = $cText
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1000, 660)
$form.MinimumSize = New-Object System.Drawing.Size(820, 520)
try { if ($IsExe) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($SelfPath) } } catch {}

function New-Ctl($type, $parent, $props) {
    $c = New-Object $type
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    if ($parent) { $parent.Controls.Add($c) }
    $c
}
function Pt($x, $y) { New-Object System.Drawing.Point($x, $y) }
function Sz($w, $h) { New-Object System.Drawing.Size($w, $h) }
function Style-Button($b, $primary) {
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = 'Hand'; $b.Font = $fBold
    if ($primary) { $b.BackColor = $cAccent; $b.ForeColor = [System.Drawing.Color]::White } else { $b.BackColor = $cCardHi; $b.ForeColor = $cText }
}

# ---- sidebar
$side = New-Ctl System.Windows.Forms.Panel $form @{ Dock = 'Left'; Width = 190; BackColor = $cSide }
$brand = New-Ctl System.Windows.Forms.Label $side @{ Text = 'RichPresence'; Font = $fTitle; ForeColor = $cText; Location = (Pt 16 16); AutoSize = $true }
$brandSub = New-Ctl System.Windows.Forms.Label $side @{ Text = 'your games on Discord'; Font = $fSmall; ForeColor = $cDim; Location = (Pt 18 50); AutoSize = $true }
$navButtons = @{}
$navY = 92
foreach ($n in 'Games', 'Music & Apps', 'Settings', 'Log') {
    $b = New-Ctl System.Windows.Forms.Button $side @{ Text = "   $n"; UseMnemonic = $false; TextAlign = 'MiddleLeft'; Location = (Pt 0 $navY); Size = (Sz 190 40) }
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Font = $fBold; $b.ForeColor = $cDim; $b.BackColor = $cSide; $b.Cursor = 'Hand'
    $navButtons[$n] = $b; $navY += 42
}
$statusLbl = New-Ctl System.Windows.Forms.Label $side @{ Text = 'Presence off'; ForeColor = $cDim; Font = $fSmall; Location = (Pt 16 590); Size = (Sz 166 30); Anchor = 'Bottom, Left' }
$btnToggle = New-Ctl System.Windows.Forms.Button $side @{ Text = 'Start presence'; Location = (Pt 12 620); Size = (Sz 166 32); Anchor = 'Bottom, Left' }
Style-Button $btnToggle $true

$content = New-Ctl System.Windows.Forms.Panel $form @{ Dock = 'Fill'; BackColor = $cBg }
$content.BringToFront()

function New-Page { New-Ctl System.Windows.Forms.Panel $content @{ Dock = 'Fill'; BackColor = $cBg; Visible = $false; Padding = (New-Object System.Windows.Forms.Padding(20)) } }
$pGames = New-Page; $pMusic = New-Page; $pSettings = New-Page; $pLog = New-Page
$pages = @{ 'Games' = $pGames; 'Music & Apps' = $pMusic; 'Settings' = $pSettings; 'Log' = $pLog }
function Show-Page($name) {
    foreach ($k in $pages.Keys) {
        $pages[$k].Visible = ($k -eq $name)
        $navButtons[$k].BackColor = $(if ($k -eq $name) { $cCardHi } else { $cSide })
        $navButtons[$k].ForeColor = $(if ($k -eq $name) { $cText } else { $cDim })
    }
}
foreach ($k in $navButtons.Keys) { $navButtons[$k].Tag = $k; $navButtons[$k].add_Click({ Show-Page $this.Tag }) }

# ---- Games page
$gHead = New-Ctl System.Windows.Forms.Panel $pGames @{ Dock = 'Top'; Height = 60 }
$gTitle = New-Ctl System.Windows.Forms.Label $gHead @{ Text = 'My games'; Font = $fTitle; Location = (Pt 0 6); AutoSize = $true }
$gCount = New-Ctl System.Windows.Forms.Label $gHead @{ Text = ''; ForeColor = $cDim; Location = (Pt 3 40); AutoSize = $true }
$txtSearch = New-Ctl System.Windows.Forms.TextBox $gHead @{ Location = (Pt 300 12); Size = (Sz 170 24); BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle' }
$btnRescan = New-Ctl System.Windows.Forms.Button $gHead @{ Text = 'Rescan'; Location = (Pt 484 9); Size = (Sz 84 30) }
$btnAdd    = New-Ctl System.Windows.Forms.Button $gHead @{ Text = '+ Add game'; Location = (Pt 576 9); Size = (Sz 104 30) }
Style-Button $btnRescan $false; Style-Button $btnAdd $false
$flow = New-Ctl System.Windows.Forms.FlowLayoutPanel $pGames @{ Dock = 'Fill'; AutoScroll = $true; BackColor = $cBg; Padding = (New-Object System.Windows.Forms.Padding(0, 6, 0, 0)) }
$flow.BringToFront()
$emptyLbl = New-Ctl System.Windows.Forms.Label $pGames @{ Text = 'Looking for your games...'; ForeColor = $cDim; Font = $fBold; Dock = 'Top'; Height = 40; Visible = $false }

# ---- Music & Apps page
$mTitle = New-Ctl System.Windows.Forms.Label $pMusic @{ Text = 'Music & apps'; UseMnemonic = $false; Font = $fTitle; Location = (Pt 20 20); AutoSize = $true }
$mNote = New-Ctl System.Windows.Forms.Label $pMusic @{ Text = "These show as their own Discord cards next to your game (up to three at once).`nApple Music: use the Microsoft Store app."; ForeColor = $cDim; Location = (Pt 22 58); AutoSize = $true }
function New-Check($parent, $text, $y) { New-Ctl System.Windows.Forms.CheckBox $parent @{ Text = $text; Location = (Pt 24 $y); AutoSize = $true; ForeColor = $cText } }
$chkMusic  = New-Check $pMusic 'Show what I''m playing on Apple Music' 110
$chkLyrics = New-Check $pMusic 'Show the current lyric line' 138
$chkArt    = New-Check $pMusic 'Show album art' 166
$chkApps   = New-Check $pMusic 'Show the app I''m using when nothing else is showing' 194
$btnMusicSave = New-Ctl System.Windows.Forms.Button $pMusic @{ Text = 'Apply'; Location = (Pt 24 250); Size = (Sz 100 32) }
Style-Button $btnMusicSave $true

# ---- Settings page
$sTitle = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Settings'; Font = $fTitle; Location = (Pt 20 20); AutoSize = $true }
$uidLbl = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Genshin UID (optional - shows your name, AR and World Level on your Genshin card)'; ForeColor = $cDim; Location = (Pt 22 64); AutoSize = $true }
$txtUid = New-Ctl System.Windows.Forms.TextBox $pSettings @{ Location = (Pt 24 88); Size = (Sz 200 24); BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle' }
$fLbl = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Extra game folders - one per line. Every sub-folder in them counts as a game.'; ForeColor = $cDim; Location = (Pt 22 130); AutoSize = $true }
$txtFolders = New-Ctl System.Windows.Forms.TextBox $pSettings @{ Location = (Pt 24 154); Size = (Sz 460 70); Multiline = $true; BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle'; ScrollBars = 'Vertical' }
$btnFolder = New-Ctl System.Windows.Forms.Button $pSettings @{ Text = 'Add folder...'; Location = (Pt 494 154); Size = (Sz 110 30) }
Style-Button $btnFolder $false
$chkAutoStart = New-Check $pSettings 'Start the presence when RichPresence opens' 246
$chkExit      = New-Check $pSettings 'Quit RichPresence when the game I launched closes' 274
$chkTray      = New-Check $pSettings 'Closing the window keeps it running in the tray' 302
$chkWin       = New-Check $pSettings 'Start with Windows' 330
$chkOfficial  = New-Check $pSettings 'Let Discord detect official games first (keeps streaks), then show my card after 2 minutes' 358
$chkUpdate    = New-Check $pSettings 'Install updates automatically (never while a game is running)' 386
$btnSave = New-Ctl System.Windows.Forms.Button $pSettings @{ Text = 'Save && rescan'; Location = (Pt 24 426); Size = (Sz 140 34) }
$btnUpdate = New-Ctl System.Windows.Forms.Button $pSettings @{ Text = 'Check for updates'; Location = (Pt 174 426); Size = (Sz 150 34) }
Style-Button $btnUpdate $false
$updateLbl = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = "Version $AppVersion"; ForeColor = $cDim; Location = (Pt 334 436); AutoSize = $true }
Style-Button $btnSave $true
$linkGuide = New-Ctl System.Windows.Forms.LinkLabel $pSettings @{ Text = 'Help & source on GitHub'; UseMnemonic = $false; Location = (Pt 24 476); AutoSize = $true; LinkColor = $cAccent }

# ---- Log page
$log = New-Ctl System.Windows.Forms.TextBox $pLog @{ Dock = 'Fill'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; BackColor = $cCard; ForeColor = $cText; BorderStyle = 'None'; Font = (New-Object System.Drawing.Font('Consolas', 9)) }

# ---- settings <-> UI
function Apply-ToUi {
    $txtUid.Text = "$($Settings.genshin_uid)"
    $txtFolders.Text = (@($Settings.extra_folders) -join [Environment]::NewLine)
    $chkMusic.Checked = [bool]$Settings.show_music; $chkLyrics.Checked = [bool]$Settings.show_lyrics
    $chkArt.Checked = [bool]$Settings.show_album_art; $chkApps.Checked = [bool]$Settings.show_current_app
    $chkAutoStart.Checked = [bool]$Settings.start_presence_on_open; $chkExit.Checked = [bool]$Settings.exit_when_game_closes
    $chkTray.Checked = [bool]$Settings.close_to_tray; $chkWin.Checked = [bool]$Settings.start_with_windows
    $chkOfficial.Checked = [bool]$Settings.official_to_discord
    $chkUpdate.Checked = [bool]$Settings.auto_update
}
function Read-FromUi {
    $Settings.genshin_uid = $txtUid.Text.Trim()
    $Settings.extra_folders = @($txtFolders.Text -split "`r?`n" | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
    $Settings.show_music = $chkMusic.Checked; $Settings.show_lyrics = $chkLyrics.Checked
    $Settings.show_album_art = $chkArt.Checked; $Settings.show_current_app = $chkApps.Checked
    $Settings.start_presence_on_open = $chkAutoStart.Checked; $Settings.exit_when_game_closes = $chkExit.Checked
    $Settings.close_to_tray = $chkTray.Checked; $Settings.start_with_windows = $chkWin.Checked
    $Settings.official_to_discord = $chkOfficial.Checked
    $Settings.auto_update = $chkUpdate.Checked
    Save-Settings $Settings
}
function Append-Log($line) {
    $log.AppendText($line + [Environment]::NewLine)
    if ($log.TextLength -gt 30000) { $log.Text = $log.Text.Substring(15000) }
}
function Set-StartupShortcut($enable) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'RichPresence.lnk'
    if (-not $enable) { if (Test-Path $lnk) { Remove-Item $lnk -Force }; return }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    if ($IsExe) { $s.TargetPath = $SelfPath; $s.Arguments = '' }
    else { $s.TargetPath = 'powershell.exe'; $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`"" }
    $s.WindowStyle = 7; $s.Save()
}

# ---- presence control
function Push-GamesToEngine { $Sync.Games = New-EngineGames $script:Library $Settings }
function Start-Presence {
    if ($script:Job) { return }
    Read-FromUi
    $Sync.Stop = $false; $Sync.GameExited = $false; $Sync.Status = 'Starting...'
    Push-GamesToEngine
    $copy = @{}
    foreach ($k in @($Settings.Keys)) { $copy[$k] = $Settings[$k] }
    $copy = Add-BuiltInIds $copy
    $script:Job = Start-Block $Engine @($copy, $Sync)
    $btnToggle.Text = 'Stop presence'
}
function Stop-Presence {
    if (-not $script:Job) { return }
    $btnToggle.Enabled = $false; $form.Cursor = 'WaitCursor'
    Stop-Block $script:Job $Sync 8000
    $script:Job = $null
    $Sync.Status = 'Stopped'; $Sync.RunningIds = @()
    $btnToggle.Text = 'Start presence'; $btnToggle.Enabled = $true; $form.Cursor = 'Default'
}
function Start-Scan {
    if ($script:ScanJob -and -not $script:ScanJob.Handle.IsCompleted) { return }
    if ($script:ScanJob) { Stop-Block $script:ScanJob $null 0 }
    $Sync.ScanDone = $false
    $emptyLbl.Visible = ($script:Library.Count -eq 0)
    $btnRescan.Text = 'Scanning...'; $btnRescan.Enabled = $false
    $copy = @{ extra_folders = @($Settings.extra_folders); custom_games = @($Settings.custom_games) }
    $script:ScanJob = Start-Block $Scanner @($copy, $Sync, $DataDir)
}

function Play-Game($g) {
    if (-not $g.launch) { return }
    try {
        if ("$($g.launch)" -match '^[a-z.]+://') { Start-Process $g.launch }
        else { Start-Process -FilePath $g.launch -WorkingDirectory (Split-Path $g.launch) }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't start $($g.name): $($_.Exception.Message)`n`nSome games need to be started as administrator - try running RichPresence as administrator.", 'RichPresence') | Out-Null
        return
    }
    Append-Log ("[{0}] Launching {1}" -f (Get-Date -Format 'HH:mm:ss'), $g.name)
    if ($Settings.exit_when_game_closes) { $Sync.WatchId = $g.id }
    if (-not $script:Job) { Start-Presence }
}

function New-Shortcut($g) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $safe = ($g.name -replace '[\\/:*?"<>|]', '')
        $s = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "$safe (RichPresence).lnk"))
        if ($IsExe) { $s.TargetPath = $SelfPath; $s.Arguments = "-Play `"$($g.id)`""; $s.IconLocation = "$($g.icon),0" }
        else { $s.TargetPath = 'powershell.exe'; $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -Play `"$($g.id)`"" }
        $s.Save()
        [System.Windows.Forms.MessageBox]::Show("Added `"$safe (RichPresence)`" to your desktop.", 'RichPresence') | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'RichPresence') | Out-Null }
}

# ---- tiles
function Get-TileImage($g) {
    try {
        if ($g.art -and (Test-Path $g.art)) {
            $bytes = [IO.File]::ReadAllBytes($g.art)
            $ms = New-Object IO.MemoryStream(, $bytes)
            return (New-Object System.Drawing.Bitmap([System.Drawing.Image]::FromStream($ms)))
        }
    } catch {}
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($g.icon)
        $bmp = New-Object System.Drawing.Bitmap(210, 100)
        $gr = [System.Drawing.Graphics]::FromImage($bmp)
        $gr.Clear($cCardHi); $gr.InterpolationMode = 'HighQualityBicubic'
        $gr.DrawImage($ico.ToBitmap(), 73, 18, 64, 64); $gr.Dispose()
        return $bmp
    } catch { return $null }
}

function Add-Tile($g) {
    $tile = New-Ctl System.Windows.Forms.Panel $null @{ Size = (Sz 210 236); BackColor = $cCard; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 14, 14)) }
    $pic = New-Ctl System.Windows.Forms.PictureBox $tile @{ Location = (Pt 0 0); Size = (Sz 210 100); SizeMode = 'Zoom'; BackColor = $cCardHi }
    $img = Get-TileImage $g; if ($img) { $pic.Image = $img }
    $name = New-Ctl System.Windows.Forms.Label $tile @{ Text = $g.name; Font = $fBold; Location = (Pt 10 108); Size = (Sz 190 22); AutoEllipsis = $true }
    $sub = New-Ctl System.Windows.Forms.Label $tile @{ Text = "$($g.store)"; ForeColor = $cDim; Font = $fSmall; Location = (Pt 10 130); Size = (Sz 190 18) }
    $disc = New-Ctl System.Windows.Forms.Label $tile @{ Font = $fSmall; Location = (Pt 10 150); Size = (Sz 190 18) }
    if ($g.discordId) { $disc.Text = 'Official Discord game'; $disc.ForeColor = $cGreen } else { $disc.Text = 'Shows as a generic game'; $disc.ForeColor = $cDim }
    $chk = New-Ctl System.Windows.Forms.CheckBox $tile @{ Text = 'Show on Discord'; Location = (Pt 8 172); AutoSize = $true; ForeColor = $cText }
    $chk.Checked = (@($Settings.disabled_games) -notcontains $g.id)
    $play = New-Ctl System.Windows.Forms.Button $tile @{ Text = 'Play'; Location = (Pt 10 198); Size = (Sz 190 30) }
    Style-Button $play $true
    $chk.Tag = $g; $play.Tag = $g
    $chk.add_CheckedChanged({
        $gg = $this.Tag
        $dis = @($Settings.disabled_games | Where-Object { $_ -ne $gg.id })
        if (-not $this.Checked) { $dis += $gg.id }
        $Settings.disabled_games = $dis; Save-Settings $Settings; Push-GamesToEngine
    })
    $play.add_Click({ Play-Game $this.Tag })

    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $mi1 = $cm.Items.Add('Create desktop shortcut'); $mi1.Tag = $g; $mi1.add_Click({ New-Shortcut $this.Tag })
    $mi2 = $cm.Items.Add('Open install folder');     $mi2.Tag = $g; $mi2.add_Click({ Start-Process explorer.exe $this.Tag.install })
    if ($g.store -eq 'Added') {
        $mi3 = $cm.Items.Add('Remove from list'); $mi3.Tag = $g
        $mi3.add_Click({
            $gg = $this.Tag
            $Settings.custom_games = @($Settings.custom_games | Where-Object { "custom:$("$($_.exe)".ToLower())" -ne $gg.id })
            Save-Settings $Settings; Start-Scan
        })
    }
    $tile.ContextMenuStrip = $cm; $pic.ContextMenuStrip = $cm
    $flow.Controls.Add($tile)
    $script:Tiles[$g.id] = [pscustomobject]@{ Tile = $tile; Sub = $sub; Game = $g }
}

function Rebuild-Tiles {
    $flow.SuspendLayout()
    foreach ($c in @($flow.Controls)) { $c.Dispose() }
    $flow.Controls.Clear(); $script:Tiles = @{}
    $q = $txtSearch.Text.Trim().ToLower()
    $shown = 0
    foreach ($g in $script:Library) {
        if ($q -and $g.name.ToLower() -notlike "*$q*") { continue }
        Add-Tile $g; $shown++
    }
    $flow.ResumeLayout()
    $gCount.Text = "$($script:Library.Count) games found"
    $emptyLbl.Visible = ($script:Library.Count -eq 0)
    if ($script:Library.Count -eq 0 -and $script:ScanJob -and $script:ScanJob.Handle.IsCompleted) { $emptyLbl.Text = "No games found. Use '+ Add game', or add folders in Settings." }
}

# ---- tray
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'RichPresence'
try { $tray.Icon = if ($form.Icon) { $form.Icon } else { [System.Drawing.SystemIcons]::Application } } catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open', $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$menu.Items.Add('Start / Stop presence', $null, { if ($script:Job) { Stop-Presence } else { Start-Presence } })
[void]$menu.Items.Add('Quit', $null, { $script:reallyQuit = $true; $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

# ---- events
$btnToggle.add_Click({ if ($script:Job) { Stop-Presence } else { Start-Presence } })
$btnRescan.add_Click({ Read-FromUi; Start-Scan })
$btnMusicSave.add_Click({ Read-FromUi; if ($script:Job) { Stop-Presence; Start-Presence } })
$btnSave.add_Click({ Read-FromUi; if ($script:Job) { Stop-Presence; Start-Presence }; Start-Scan; Show-Page 'Games' })
$btnFolder.add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Pick a folder that contains your games (each sub-folder is one game)'
    if ($d.ShowDialog() -eq 'OK') { $txtFolders.AppendText($(if ($txtFolders.TextLength) { [Environment]::NewLine } else { '' }) + $d.SelectedPath) }
})
$btnAdd.add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Game (*.exe)|*.exe'; $d.Title = 'Pick the game''s .exe'
    if ($d.ShowDialog() -eq 'OK') {
        $fi = Get-Item $d.FileName
        $nm = $fi.VersionInfo.ProductName; if (-not $nm) { $nm = $fi.BaseName }
        $Settings.custom_games = @($Settings.custom_games) + @(@{ name = $nm; exe = $fi.FullName })
        Save-Settings $Settings; Start-Scan
    }
})
$txtSearch.add_TextChanged({ Rebuild-Tiles })
$chkWin.add_CheckedChanged({ try { Set-StartupShortcut $chkWin.Checked } catch {} })
$linkGuide.add_Click({ Start-Process $RepoUrl })

# ---- updates
$script:UpdateJob = $null
$script:NextUpdateCheck = [datetime]::MaxValue
function Start-UpdateCheck {
    if ($script:UpdateJob -and -not $script:UpdateJob.Handle.IsCompleted) { return }
    if ($script:UpdateJob) { Stop-Block $script:UpdateJob $null 0 }
    $Sync.UpdateState = 'checking'
    $updateLbl.Text = "Version $AppVersion - checking for updates..."
    $script:UpdateJob = Start-Block $Updater @($Sync, $AppVersion, $DataDir)
    $script:NextUpdateCheck = (Get-Date).AddHours(6)
}
# The running EXE can't overwrite itself: a tiny helper waits for this process to exit,
# swaps the file in, and starts the new version.
function Install-Update {
    $new = $Sync.UpdateFile
    if (-not $new -or -not (Test-Path $new)) { return }
    if (-not $IsExe) { $updateLbl.Text = "Version $($Sync.LatestVersion) is available on GitHub (running as a script, so update by hand)."; return }
    $helper = Join-Path (Split-Path $new) 'apply-update.cmd'
    @"
@echo off
:wait
tasklist /FI "PID eq $PID" 2>nul | find "$PID" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)
copy /y "$new" "$SelfPath" >nul || goto done
del "$new" >nul 2>&1
:done
start "" "$SelfPath"
"@ | Set-Content -Path $helper -Encoding ASCII
    Append-Log ("[{0}] Installing update {1} and restarting..." -f (Get-Date -Format 'HH:mm:ss'), $Sync.LatestVersion)
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$helper`"" -WindowStyle Hidden
    $script:reallyQuit = $true
    $form.Close()
}
$btnUpdate.add_Click({
    if ($Sync.UpdateState -eq 'ready') { Install-Update } else { Start-UpdateCheck }
})
$form.add_FormClosing({
    param($s, $e)
    if ($Settings.close_to_tray -and -not $script:reallyQuit -and $e.CloseReason -eq 'UserClosing') {
        $e.Cancel = $true; Read-FromUi; $form.Hide()
        $tray.ShowBalloonTip(2000, 'RichPresence', 'Still running in the tray.', 'Info')
        return
    }
    try { Read-FromUi } catch {}
    Stop-Presence
    if ($script:ScanJob) { Stop-Block $script:ScanJob $null 0 }
    $tray.Visible = $false; $tray.Dispose()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    $line = $null
    while ($Sync.Queue.TryDequeue([ref]$line)) { Append-Log $line }

    # updates: check every 6 hours; install when ready unless a game is running (or it's set to ask)
    if ((Get-Date) -ge $script:NextUpdateCheck) { Start-UpdateCheck }
    switch ($Sync.UpdateState) {
        'current' { $updateLbl.Text = "Version $AppVersion - up to date"; $btnUpdate.Text = 'Check for updates'; $Sync.UpdateState = 'shown' }
        'failed'  { $updateLbl.Text = "Version $AppVersion - couldn't check (see Log)"; $Sync.UpdateState = 'shown' }
        'ready' {
            $updateLbl.Text = "Version $($Sync.LatestVersion) is ready"
            $btnUpdate.Text = 'Restart to update'
            if ($Settings.auto_update -and @($Sync.RunningIds).Count -eq 0) { $Sync.UpdateState = 'installing'; Install-Update }
        }
    }

    if ($Sync.ScanDone -and $script:ScanJob) {
        $Sync.ScanDone = $false
        $script:Library = @(Read-Library)
        $btnRescan.Text = 'Rescan'; $btnRescan.Enabled = $true
        Rebuild-Tiles; Push-GamesToEngine
        if ($script:PendingPlay) {
            $g = $script:Library | Where-Object { $_.id -eq $script:PendingPlay } | Select-Object -First 1
            $script:PendingPlay = ''
            if ($g) { Play-Game $g }
        }
    }

    if ($script:Job) {
        $statusLbl.Text = "Presence on`n$($Sync.Status)"; $statusLbl.ForeColor = $cGreen
        if ($script:Job.Handle.IsCompleted) { Stop-Presence }
        if ($Settings.exit_when_game_closes -and $Sync.GameExited) { $script:reallyQuit = $true; $form.Close() }
    } else {
        $statusLbl.Text = 'Presence off'; $statusLbl.ForeColor = $cDim
    }
    foreach ($id in @($script:Tiles.Keys)) {
        $t = $script:Tiles[$id]
        $isRun = @($Sync.RunningIds) -contains $id
        $t.Tile.BackColor = $(if ($isRun) { C '#243a2e' } else { $cCard })
        $t.Sub.Text = $(if ($isRun) { "$($t.Game.store)  -  Running" } else { "$($t.Game.store)" })
    }
})

Apply-ToUi
Show-Page 'Games'
Rebuild-Tiles
$timer.Start()

$form.add_Shown({
    Start-Scan
    $script:NextUpdateCheck = (Get-Date).AddSeconds(20)   # first check shortly after opening
    if ($Settings.start_presence_on_open -or $script:PendingPlay) { Start-Presence }
    if ($script:PendingPlay -and $script:Library.Count) {
        $g = $script:Library | Where-Object { $_.id -eq $script:PendingPlay } | Select-Object -First 1
        if ($g) { $script:PendingPlay = ''; Play-Game $g }
    }
})

[System.Windows.Forms.Application]::Run($form)
$mutex.ReleaseMutex()
