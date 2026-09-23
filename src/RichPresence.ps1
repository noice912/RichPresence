<#
  RichPresence  -  launcher + Discord Rich Presence for Genshin Impact, Apple Music and your apps.

  Run as a script:  powershell -ExecutionPolicy Bypass -File RichPresence.ps1
  Or compile it:    .\build.ps1   ->  dist\RichPresence.exe

    -Launch     start Genshin (from the saved game path) and the presence right away
    -Headless   no window; run the presence engine in the console (debugging)
#>
param(
    [switch]$Launch,
    [switch]$Headless
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppName      = 'RichPresence'
$DataDir      = if ($env:RICHPRESENCE_DATA) { $env:RICHPRESENCE_DATA } else { Join-Path $env:APPDATA 'RichPresence' }
$SettingsPath = Join-Path $DataDir 'settings.json'
$CiderId      = '911790844204437504'   # Cider's public Discord app - works out of the box for music / apps

# ===========================================================================
# Settings
# ===========================================================================
function New-DefaultSettings {
    [ordered]@{
        main_client_id      = $CiderId
        genshin_client_id   = ''
        genshin_uid         = ''
        game_path           = ''
        show_genshin        = $true
        show_music          = $true
        show_lyrics         = $true
        show_album_art      = $true
        show_current_app    = $true
        launch_on_open      = $false   # click Launch automatically when RichPresence opens
        start_presence_on_open = $true
        exit_when_game_closes  = $false
        start_with_windows  = $false
        close_to_tray       = $true
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
    return $s
}

function Save-Settings($s) {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    ($s | ConvertTo-Json) | Set-Content -Path $SettingsPath -Encoding UTF8
}

# ===========================================================================
# ENGINE - runs on a background runspace. Talks to Discord, reads Apple Music,
# the foreground window and the Genshin process. Never touches the UI directly;
# it only writes to $Sync (log queue + status fields).
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

    $ClientId        = "$($S.main_client_id)".Trim()
    $GenshinClientId = "$($S.genshin_client_id)".Trim()
    $GenshinUid      = "$($S.genshin_uid)".Trim()
    $ShowGenshin     = [bool]$S.show_genshin
    $ShowMusic       = [bool]$S.show_music
    $ShowLyrics      = [bool]$S.show_lyrics
    $ShowArt         = [bool]$S.show_album_art
    $ShowApps        = [bool]$S.show_current_app

    if ($ClientId -notmatch '^\d{17,20}$') { Log "The main Discord app ID isn't valid (17-20 digits). Fix it in Settings."; return }
    $DualMode = $ShowGenshin -and ($GenshinClientId -match '^\d{17,20}$') -and ($GenshinClientId -ne $ClientId)
    if ($ShowGenshin -and -not $DualMode) {
        Log "No separate Genshin app ID set - Genshin will replace the music card instead of showing next to it."
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
    if ($DualMode) { $Ignore += @('genshinimpact', 'yuanshen') }
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
    function Get-Foreground {
        $h = [RPFG]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $null }
        $procId = 0; [RPFG]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
        if ($procId -le 0) { return $null }
        try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { return $null }
        $name = $p.ProcessName
        if ($Ignore -contains $name.ToLower()) { return $null }
        $label = $Friendly[$name.ToLower()]
        if (-not $label) { try { $label = $p.MainModule.FileVersionInfo.FileDescription } catch {} }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        $icon = if ($IconDomain.ContainsKey($name.ToLower())) { "https://www.google.com/s2/favicons?sz=128&domain=$($IconDomain[$name.ToLower()])" } else { $null }
        [pscustomobject]@{ Proc = $name.ToLower(); Label = "$label"; Title = "$([RPFG]::Title($h))"; Icon = $icon }
    }

    # ---------------------------------------------------------------- Genshin (process + Enka.Network profile)
    $script:GenshinInfo = $null; $script:GenshinFetchedAt = [datetime]::MinValue
    function Get-GenshinProcess { Get-Process -Name 'GenshinImpact', 'YuanShen' -ErrorAction SilentlyContinue | Select-Object -First 1 }
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
    function New-GenshinActivity($gp, $gi) {
        $startMs = ([DateTimeOffset]$gp.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
        $a = @{ type = 0; name = 'Genshin Impact'; timestamps = @{ start = $startMs } }
        if ($gi) { $a.details = "$($gi.Nickname) - AR $($gi.Level)"; $a.state = "UID $GenshinUid - WL $($gi.WorldLevel)" }
        else     { $a.details = 'Exploring Teyvat' }
        $a.assets = @{ large_image = 'https://www.google.com/s2/favicons?sz=128&domain=genshin.hoyoverse.com'; large_text = 'Genshin Impact' }
        return $a
    }

    # ---------------------------------------------------------------- Discord IPC (one connection per app id)
    $ConnMain = @{ Pipe = $null; ClientId = $ClientId;        Name = 'main' }
    $ConnGame = @{ Pipe = $null; ClientId = $GenshinClientId; Name = 'genshin' }
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
                Log "Connected to Discord ($($c.Name))"
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

    # Genshin on its own connection (dual mode)
    $script:gameId = $null; $script:gameSentUtc = [datetime]::MinValue
    function Update-GamePresence($gp) {
        try {
            if ($gp) {
                if (-not (Connect-Discord $ConnGame)) { return }
                $gi = Get-GenshinInfo
                $id = "genshin|$($gi.Nickname)|$($gi.WorldLevel)|$($gi.Level)"
                if (($script:gameId -ne $id) -or (([datetime]::UtcNow - $script:gameSentUtc).TotalSeconds -ge 20)) {
                    Set-Activity $ConnGame (New-GenshinActivity $gp $gi)
                    if ($script:gameId -ne $id) { Log "Genshin card shown" }
                    $script:gameId = $id; $script:gameSentUtc = [datetime]::UtcNow
                }
            } elseif ($ConnGame.Pipe) {
                Close-Discord $ConnGame; $script:gameId = $null
                Log "Genshin closed - card removed"
            }
        } catch { Log "Genshin card error: $($_.Exception.Message)"; Close-Discord $ConnGame; $script:gameId = $null }
    }

    # ---------------------------------------------------------------- main loop
    $FALLBACK_IMAGE   = 'https://upload.wikimedia.org/wikipedia/commons/thumb/5/5f/Apple_Music_icon.svg/240px-Apple_Music_icon.svg.png'
    $GENERIC_APP_ICON = 'https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Windows_logo_-_2021.svg/240px-Windows_logo_-_2021.svg.png'
    $script:sourceId = $null; $script:lastSendUtc = [datetime]::MinValue
    $lastLyricLine = $null; $appStartMs = $null; $appPendProc = $null; $appPendSince = [datetime]::MinValue
    $lastValidAppUtc = $null; $idleCleared = $false; $sawGame = $false; $goneSince = $null

    function Push-Activity($activity, $id, $critical) {
        $since = ([datetime]::UtcNow - $script:lastSendUtc).TotalSeconds
        if (-not $critical -and $since -lt 5) { return $false }
        if ($critical -and $since -lt 2) { Start-Sleep -Milliseconds 800 }
        Set-Activity $ConnMain $activity
        $script:lastSendUtc = [datetime]::UtcNow
        $script:sourceId = $id
        return $true
    }

    Log "Presence started."
    while (-not $Sync.Stop) {
        try {
            if (-not (Connect-Discord $ConnMain)) { $Sync.Status = 'Waiting for Discord...'; Nap 10; continue }

            # Genshin process bookkeeping (also drives "exit when the game closes")
            $gp = Get-GenshinProcess
            $Sync.GameRunning = [bool]$gp
            if ($gp) { $sawGame = $true; $goneSince = $null }
            elseif ($sawGame) {
                if (-not $goneSince) { $goneSince = [datetime]::UtcNow }
                elseif (([datetime]::UtcNow - $goneSince).TotalSeconds -gt 8) { $sawGame = $false; $Sync.GameExited = $true }
            }
            if ($DualMode) { Update-GamePresence $gp }

            # what's playing
            $session = if ($ShowMusic) { Get-AppleMusicSession } else { $null }
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
            $musicActive = ($status -eq 'Playing' -and $title)

            # G) Genshin on the main card (only when there's no separate Genshin app id)
            if ($ShowGenshin -and -not $DualMode -and $gp) {
                $idleCleared = $false
                $gi = Get-GenshinInfo
                $id = "genshin|$($gi.Nickname)|$($gi.WorldLevel)|$($gi.Level)"
                if (($script:sourceId -ne $id) -or (([datetime]::UtcNow - $script:lastSendUtc).TotalSeconds -ge 20)) {
                    Push-Activity (New-GenshinActivity $gp $gi) $id ($script:sourceId -notlike 'genshin|*') | Out-Null
                }
                $Sync.Status = 'Showing Genshin'; Nap 3; continue
            }

            # A) music
            if ($musicActive) {
                $idleCleared = $false
                $lyrics  = Get-SyncedLyrics $artist $title $album $duration
                $curLine = Get-CurrentLyricLine $lyrics $position
                $id = "music|$artist|$title|$album"
                $trackChanged = ($script:sourceId -ne $id)
                $lyricChanged = ($ShowLyrics -and $curLine -and $curLine -ne $lastLyricLine)
                if ($trackChanged -or $lyricChanged -or (([datetime]::UtcNow - $script:lastSendUtc).TotalSeconds -ge 15)) {
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
                    if (Push-Activity $activity $id $trackChanged) {
                        if ($trackChanged) { Log "Music: $artist - $title"; $lastLyricLine = $null }
                        if ($lyricChanged) { $lastLyricLine = $curLine }
                    }
                }
                $Sync.Status = "Listening: $title"; Nap 3; continue
            }

            # B) current app
            if ($ShowApps) {
                $fg = Get-Foreground
                if ($fg) {
                    $lastValidAppUtc = [datetime]::UtcNow
                    if ($fg.Proc -ne $appPendProc) { $appPendProc = $fg.Proc; $appPendSince = [datetime]::UtcNow }
                    $settled = ([datetime]::UtcNow - $appPendSince).TotalSeconds
                    $id = "app|$($fg.Label)"
                    $isNew = ($script:sourceId -ne $id) -and ($settled -ge 3)
                    if ($isNew -or ($script:sourceId -eq $id) -or (([datetime]::UtcNow - $script:lastSendUtc).TotalSeconds -ge 20)) {
                        if ($isNew -or -not $appStartMs) { $appStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                        $detail = $fg.Title; if ($detail.Length -gt 128) { $detail = $detail.Substring(0, 125) + '...' }
                        $activity = @{ type = 0; name = $fg.Label; timestamps = @{ start = $appStartMs } }
                        if ($detail -and $detail -ne $fg.Label) { $activity.details = $detail }
                        $activity.assets = @{ large_image = $(if ($fg.Icon) { $fg.Icon } else { $GENERIC_APP_ICON }); large_text = $fg.Label }
                        if (Push-Activity $activity $id $isNew) { if ($isNew) { Log "App: $($fg.Label)" } }
                    }
                    $idleCleared = $false; $Sync.Status = "Showing: $($fg.Label)"; Nap 3; continue
                }
                # ignored window (e.g. Discord itself): keep the last app for a few minutes
                if (("$($script:sourceId)" -like 'app|*') -and $lastValidAppUtc -and (([datetime]::UtcNow - $lastValidAppUtc).TotalSeconds -lt 300)) { Nap 3; continue }
            }

            # C) nothing to show
            if (-not $idleCleared) { Clear-Activity $ConnMain; $idleCleared = $true; $script:sourceId = $null }
            $Sync.Status = 'Idle - nothing to show'
            Nap 4
        }
        catch {
            Log "Error: $($_.Exception.Message)"
            Close-Discord $ConnMain; Close-Discord $ConnGame; $script:gameId = $null
            Nap 5
        }
    }

    # stopped: remove our cards
    try { if ($ConnMain.Pipe) { Clear-Activity $ConnMain } } catch {}
    Close-Discord $ConnMain; Close-Discord $ConnGame
    Log "Presence stopped."
}

# ===========================================================================
# Runner helpers (used by both the window and -Headless)
# ===========================================================================
function New-Sync { [hashtable]::Synchronized(@{ Stop = $false; Queue = (New-Object System.Collections.Concurrent.ConcurrentQueue[string]); Status = 'Stopped'; GameRunning = $false; GameExited = $false }) }

function Start-Engine($settings, $sync) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($Engine.ToString()).AddArgument($settings).AddArgument($sync)
    [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Stop-Engine($job, $sync) {
    if (-not $job) { return }
    $sync.Stop = $true
    [void]$job.Handle.AsyncWaitHandle.WaitOne(8000)
    try { $job.PS.Dispose(); $job.RS.Dispose() } catch {}
}

if ($Headless) {
    $settings = Load-Settings
    $sync = New-Sync
    $job = Start-Engine $settings $sync
    Write-Host "RichPresence (headless) - Ctrl+C to stop"
    try {
        while ($true) {
            $line = $null
            while ($sync.Queue.TryDequeue([ref]$line)) { Write-Host $line }
            if ($job.Handle.IsCompleted) { break }
            Start-Sleep -Milliseconds 300
        }
    } finally { Stop-Engine $job $sync }
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
$script:Job = $null
$script:reallyQuit = $false

$SelfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$IsExe    = $SelfPath -like '*.exe' -and $SelfPath -notmatch 'powershell|pwsh'

function Find-GamePath {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\', 'D:\', 'E:\') | Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $roots) {
        foreach ($sub in @('HoYoPlay\games\Genshin Impact game\GenshinImpact.exe', 'Genshin Impact\Genshin Impact game\GenshinImpact.exe', 'HoYoPlay\launcher.exe', 'HoYoPlay\HoYoPlay.exe', 'Genshin Impact\launcher.exe')) {
            $p = Join-Path $r $sub
            if (Test-Path $p) { return $p }
        }
    }
    return ''
}

$font  = New-Object System.Drawing.Font('Segoe UI', 9)
$bold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$big   = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$blurple = [System.Drawing.Color]::FromArgb(88, 101, 242)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'RichPresence'
$form.Font = $font
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(520, 700)
$iconFile = if ($IsExe) { $SelfPath } else { $null }
try { if ($iconFile) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconFile) } } catch {}

function Add-Ctl($parent, $ctl, $x, $y, $w, $h, $text) {
    $ctl.Location = New-Object System.Drawing.Point($x, $y)
    if ($w) { $ctl.Size = New-Object System.Drawing.Size($w, $h) }
    if ($null -ne $text) { $ctl.Text = $text }
    $parent.Controls.Add($ctl); $ctl
}

$title = Add-Ctl $form (New-Object System.Windows.Forms.Label) 16 12 300 32 'RichPresence'
$title.Font = $big; $title.ForeColor = $blurple; $title.AutoSize = $true
$sub = Add-Ctl $form (New-Object System.Windows.Forms.Label) 18 46 480 20 'Launch Genshin and show it on Discord - next to your music.'
$sub.ForeColor = [System.Drawing.Color]::Gray

$statusDot = Add-Ctl $form (New-Object System.Windows.Forms.Label) 18 74 480 22 'Stopped'
$statusDot.Font = $bold

$btnLaunch = Add-Ctl $form (New-Object System.Windows.Forms.Button) 18 102 232 44 'Launch Genshin'
$btnLaunch.Font = $bold; $btnLaunch.BackColor = $blurple; $btnLaunch.ForeColor = [System.Drawing.Color]::White; $btnLaunch.FlatStyle = 'Flat'
$btnToggle = Add-Ctl $form (New-Object System.Windows.Forms.Button) 262 102 232 44 'Start presence'
$btnToggle.Font = $bold

# --- Discord group
$gDiscord = Add-Ctl $form (New-Object System.Windows.Forms.GroupBox) 16 158 488 128 'Discord apps'
$l = Add-Ctl $gDiscord (New-Object System.Windows.Forms.Label) 12 24 460 18 'Genshin app ID  (your own - see the guide)'
$txtGenshinId = Add-Ctl $gDiscord (New-Object System.Windows.Forms.TextBox) 12 44 464 24 ''
$l = Add-Ctl $gDiscord (New-Object System.Windows.Forms.Label) 12 74 460 18 'Music / apps app ID  (default works, leave it unless you made your own)'
$txtMainId = Add-Ctl $gDiscord (New-Object System.Windows.Forms.TextBox) 12 94 464 24 ''

# --- Genshin group
$gGame = Add-Ctl $form (New-Object System.Windows.Forms.GroupBox) 16 294 488 128 'Genshin'
$l = Add-Ctl $gGame (New-Object System.Windows.Forms.Label) 12 24 200 18 'Your UID  (bottom-right in-game)'
$txtUid = Add-Ctl $gGame (New-Object System.Windows.Forms.TextBox) 12 44 200 24 ''
$l = Add-Ctl $gGame (New-Object System.Windows.Forms.Label) 12 74 460 18 'Game or HoYoPlay launcher (.exe)'
$txtPath = Add-Ctl $gGame (New-Object System.Windows.Forms.TextBox) 12 94 316 24 ''
$btnBrowse = Add-Ctl $gGame (New-Object System.Windows.Forms.Button) 334 92 68 26 'Browse'
$btnDetect = Add-Ctl $gGame (New-Object System.Windows.Forms.Button) 408 92 68 26 'Detect'

# --- Options group
$gOpt = Add-Ctl $form (New-Object System.Windows.Forms.GroupBox) 16 430 488 150 'Options'
function Add-Check($text, $x, $y, $w) { $c = Add-Ctl $gOpt (New-Object System.Windows.Forms.CheckBox) $x $y $w 22 $text; $c }
$chkGenshin = Add-Check 'Show Genshin card'        12 22 226
$chkMusic   = Add-Check 'Show Apple Music'         246 22 226
$chkLyrics  = Add-Check 'Show lyrics'              12 46 226
$chkArt     = Add-Check 'Show album art'           246 46 226
$chkApps    = Add-Check 'Show current app'         12 70 226
$chkTray    = Add-Check 'Close button hides to tray' 246 70 226
$chkAutoStart = Add-Check 'Start presence when opened' 12 94 226
$chkAutoLaunch= Add-Check 'Launch Genshin when opened' 246 94 226
$chkExit    = Add-Check 'Quit when Genshin closes'  12 118 226
$chkWin     = Add-Check 'Start with Windows'        246 118 226

# --- Log
$log = Add-Ctl $form (New-Object System.Windows.Forms.TextBox) 16 590 488 70 ''
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.Font = New-Object System.Drawing.Font('Consolas', 8)
$btnShortcut = Add-Ctl $form (New-Object System.Windows.Forms.Button) 16 666 200 26 'Desktop shortcut (launch)'
$linkGuide   = Add-Ctl $form (New-Object System.Windows.Forms.LinkLabel) 300 671 204 20 'Setup guide (GitHub)'
$linkGuide.TextAlign = 'MiddleRight'

function Apply-ToUi {
    $txtGenshinId.Text = "$($Settings.genshin_client_id)"; $txtMainId.Text = "$($Settings.main_client_id)"
    $txtUid.Text = "$($Settings.genshin_uid)"; $txtPath.Text = "$($Settings.game_path)"
    $chkGenshin.Checked = [bool]$Settings.show_genshin; $chkMusic.Checked = [bool]$Settings.show_music
    $chkLyrics.Checked = [bool]$Settings.show_lyrics; $chkArt.Checked = [bool]$Settings.show_album_art
    $chkApps.Checked = [bool]$Settings.show_current_app; $chkTray.Checked = [bool]$Settings.close_to_tray
    $chkAutoStart.Checked = [bool]$Settings.start_presence_on_open; $chkAutoLaunch.Checked = [bool]$Settings.launch_on_open
    $chkExit.Checked = [bool]$Settings.exit_when_game_closes; $chkWin.Checked = [bool]$Settings.start_with_windows
}
function Read-FromUi {
    $Settings.genshin_client_id = $txtGenshinId.Text.Trim(); $Settings.main_client_id = $txtMainId.Text.Trim()
    if (-not $Settings.main_client_id) { $Settings.main_client_id = $CiderId }
    $Settings.genshin_uid = $txtUid.Text.Trim(); $Settings.game_path = $txtPath.Text.Trim().Trim('"')
    $Settings.show_genshin = $chkGenshin.Checked; $Settings.show_music = $chkMusic.Checked
    $Settings.show_lyrics = $chkLyrics.Checked; $Settings.show_album_art = $chkArt.Checked
    $Settings.show_current_app = $chkApps.Checked; $Settings.close_to_tray = $chkTray.Checked
    $Settings.start_presence_on_open = $chkAutoStart.Checked; $Settings.launch_on_open = $chkAutoLaunch.Checked
    $Settings.exit_when_game_closes = $chkExit.Checked; $Settings.start_with_windows = $chkWin.Checked
    Save-Settings $Settings
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

function Append-Log($line) {
    $log.AppendText($line + [Environment]::NewLine)
    if ($log.TextLength -gt 20000) { $log.Text = $log.Text.Substring(10000) }
}

function Start-Presence {
    if ($script:Job) { return }
    Read-FromUi
    $Sync.Stop = $false; $Sync.GameExited = $false; $Sync.Status = 'Starting...'
    $script:Job = Start-Engine $Settings.Clone() $Sync
    $btnToggle.Text = 'Stop presence'
}
function Stop-Presence {
    if (-not $script:Job) { return }
    $btnToggle.Enabled = $false; $form.Cursor = 'WaitCursor'
    Stop-Engine $script:Job $Sync
    $script:Job = $null
    $Sync.Status = 'Stopped'; $Sync.GameRunning = $false
    $btnToggle.Text = 'Start presence'; $btnToggle.Enabled = $true; $form.Cursor = 'Default'
}

function Launch-Game {
    Read-FromUi
    $p = $Settings.game_path
    if (-not $p -or -not (Test-Path $p)) {
        $found = Find-GamePath
        if ($found) { $txtPath.Text = $found; $p = $found; Read-FromUi }
    }
    if (-not $p -or -not (Test-Path $p)) {
        [System.Windows.Forms.MessageBox]::Show("Couldn't find Genshin. Click Browse and pick GenshinImpact.exe (or the HoYoPlay launcher).", 'RichPresence') | Out-Null
        return
    }
    try { Start-Process -FilePath $p -WorkingDirectory (Split-Path $p) } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't start it: $($_.Exception.Message)`n`nGenshin usually needs to be started as administrator - try running RichPresence as administrator.", 'RichPresence') | Out-Null
        return
    }
    Append-Log ("[{0}] Launching {1}" -f (Get-Date -Format 'HH:mm:ss'), (Split-Path $p -Leaf))
    Start-Presence
}

# --- tray
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'RichPresence'
try { $tray.Icon = if ($form.Icon) { $form.Icon } else { [System.Drawing.SystemIcons]::Application } } catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open',            $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$menu.Items.Add('Launch Genshin',  $null, { Launch-Game })
[void]$menu.Items.Add('Start / Stop presence', $null, { if ($script:Job) { Stop-Presence } else { Start-Presence } })
[void]$menu.Items.Add('Quit',            $null, { $script:reallyQuit = $true; $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

# --- events
$btnLaunch.add_Click({ Launch-Game })
$btnToggle.add_Click({ if ($script:Job) { Stop-Presence } else { Start-Presence } })
$btnBrowse.add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Genshin / launcher (*.exe)|*.exe'; $d.Title = 'Pick GenshinImpact.exe or the HoYoPlay launcher'
    if ($d.ShowDialog() -eq 'OK') { $txtPath.Text = $d.FileName }
})
$btnDetect.add_Click({
    $f = Find-GamePath
    if ($f) { $txtPath.Text = $f } else { [System.Windows.Forms.MessageBox]::Show("Couldn't find it automatically - use Browse.", 'RichPresence') | Out-Null }
})
$chkWin.add_CheckedChanged({ try { Set-StartupShortcut $chkWin.Checked } catch {} })
$btnShortcut.add_Click({
    try {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Genshin (RichPresence).lnk'))
        if ($IsExe) { $s.TargetPath = $SelfPath; $s.Arguments = '-Launch'; $s.IconLocation = "$SelfPath,0" }
        else { $s.TargetPath = 'powershell.exe'; $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -Launch" }
        $s.Save()
        [System.Windows.Forms.MessageBox]::Show('Added "Genshin (RichPresence)" to your desktop. Use it to start the game with Discord presence.', 'RichPresence') | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'RichPresence') | Out-Null }
})
$linkGuide.add_Click({ Start-Process 'https://github.com/OWNER/RichPresence#readme' })
$form.add_FormClosing({
    param($s, $e)
    if ($Settings.close_to_tray -and -not $script:reallyQuit -and $e.CloseReason -eq 'UserClosing') {
        $e.Cancel = $true; Read-FromUi; $form.Hide()
        $tray.ShowBalloonTip(2000, 'RichPresence', 'Still running in the tray.', 'Info')
        return
    }
    try { Read-FromUi } catch {}
    Stop-Presence
    $tray.Visible = $false; $tray.Dispose()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    $line = $null
    while ($Sync.Queue.TryDequeue([ref]$line)) { Append-Log $line }
    if ($script:Job) {
        $game = if ($Sync.GameRunning) { 'Genshin: running' } else { 'Genshin: not running' }
        $statusDot.Text = "● Presence on  -  $($Sync.Status)  -  $game"
        $statusDot.ForeColor = [System.Drawing.Color]::FromArgb(35, 165, 90)
        if ($script:Job.Handle.IsCompleted) { Stop-Presence }   # engine bailed (bad app ID etc.)
        if ($Settings.exit_when_game_closes -and $Sync.GameExited) { $script:reallyQuit = $true; $form.Close() }
    } else {
        $statusDot.Text = '● Presence off'
        $statusDot.ForeColor = [System.Drawing.Color]::Gray
    }
})

Apply-ToUi
if (-not $Settings.game_path) { $g = Find-GamePath; if ($g) { $txtPath.Text = $g } }
$timer.Start()

$form.add_Shown({
    if ($Launch -or $Settings.launch_on_open) { Launch-Game }
    elseif ($Settings.start_presence_on_open -and ($Settings.genshin_client_id -or $Settings.main_client_id)) { Start-Presence }
})

[System.Windows.Forms.Application]::Run($form)
$mutex.ReleaseMutex()
