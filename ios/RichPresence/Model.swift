import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import Security

/// Tokens go in the Keychain, not in plain settings.
enum Keychain {
    private static let service = "io.github.noice912.richpresence.discord"

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    /// when `position` was read, so the current position can be worked out later
    var at = Date()
    var artUrl: String? = nil
    var source = "Apple Music"

    var currentPosition: TimeInterval {
        let p = position + Date().timeIntervalSince(at)
        return duration > 0 ? min(p, duration) : p
    }

    static func == (a: Track, b: Track) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album && a.source == b.source
    }
}

@MainActor
final class Model: ObservableObject {
    /// One shared instance: the screen and the Shortcuts actions both use it.
    static let shared = Model()

    @Published var game: String?
    private var gameSince = Date()
    private var keepAlive: AVAudioPlayer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// Games (and music, until the music card is linked) on "RichPresence Mobile"; music on "RichPresence Music".
    let gameLink: Link
    let musicLink: Link
    let spotify: Spotify
    var anyLinked: Bool { gameLink.name != nil || musicLink.name != nil }
    @Published var musicAllowed = MPMediaLibrary.authorizationStatus() == .authorized
    @Published var showMusic = UserDefaults.standard.object(forKey: "show_music") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMusic, forKey: "show_music"); push(force: true) }
    }
    @Published var track: Track?
    /// Keep running in the background so a new song is noticed without opening the app.
    @Published var background = UserDefaults.standard.object(forKey: "background") as? Bool ?? true {
        didSet { UserDefaults.standard.set(background, forKey: "background"); updateAwake() }
    }
    @Published var showLyrics = UserDefaults.standard.object(forKey: "show_lyrics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLyrics, forKey: "show_lyrics"); push(force: true) }
    }
    @Published var lyricLine: String?
    private var lyricsCache: [String: [(TimeInterval, String)]] = [:]
    private var lyricsLoading: Set<String> = []
    private var lyricTimer: Timer?
    // saved, so lines written while iOS ran the app in the background (Shortcuts) are still there later
    @Published var log: [String] = UserDefaults.standard.stringArray(forKey: "log") ?? []

    private var pump: Timer?
    private var poll: Timer?
    private var artCache: [String: String] = [:]

    private init() {
        func appId(_ key: String) -> UInt64 { UInt64(Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "") ?? 0 }
        var sayLater: (String) -> Void = { _ in }
        gameLink = Link(label: "Game card", appId: appId("DiscordAppId"), prefix: "", say: { sayLater($0) })
        musicLink = Link(label: "Music card", appId: appId("DiscordMusicAppId"), prefix: "music_", say: { sayLater($0) })
        spotify = Spotify(say: { sayLater($0) })
        sayLater = { [weak self] m in self?.say(m) }
        for l in [gameLink, musicLink] {
            l.onReady = { [weak self] in
                self?.push(force: true)
                self?.updateAwake()
                self?.objectWillChange.send()
            }
        }
        pump = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // one call runs the callbacks of both Discord connections
            MainActor.assumeIsolated { self?.gameLink.bridge.runCallbacks() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrack(); self?.refreshSpotify() }
        }
        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()
        for n in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            NotificationCenter.default.addObserver(forName: n, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTrack() }
            }
        }
        // the current lyric line, checked every second while a song plays
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickLyrics() }
        }
        // another app taking over the audio (a call, a game) pauses the silent sound; start it again after
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.keepAlive?.play()
            }
        }
        gameLink.signInSaved()
        musicLink.signInSaved()
        refreshTrack()
        refreshSpotify()
        updateAwake()
    }

    /// Stay running while a game is showing, or all the time when "Keep running in the background" is on.
    func updateAwake() {
        stayAwake(game != nil || (background && anyLinked))
    }

    /// Where the music card goes: its own app once linked, otherwise the game card's app when no game is showing.
    private var musicTarget: Link? {
        if musicLink.name != nil { return musicLink }
        return game == nil ? gameLink : nil
    }

    // ------------------------------------------------ lyrics (lrclib.net, like the Windows version)
    private func tickLyrics() {
        guard showLyrics, let t = track else {
            if lyricLine != nil { lyricLine = nil }
            return
        }
        let key = "\(t.artist)|\(t.title)|\(t.album)"
        guard let lines = lyricsCache[key] else { loadLyrics(t, key: key); return }
        let pos = t.source == "Apple Music" ? MPMusicPlayerController.systemMusicPlayer.currentPlaybackTime : t.currentPosition
        let line = lines.last(where: { $0.0 <= pos + 0.3 })?.1
        let clean = (line?.isEmpty ?? true) ? nil : String(line!.prefix(128))
        guard clean != lyricLine else { return }
        lyricLine = clean
        // Discord limits how often a status can change, so lines at most every 4 seconds
        if let target = musicTarget, Date().timeIntervalSince(target.sentAt) >= 4 { push(force: true) }
    }

    private func loadLyrics(_ t: Track, key: String) {
        guard !lyricsLoading.contains(key) else { return }
        lyricsLoading.insert(key)
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [.init(name: "artist_name", value: t.artist), .init(name: "track_name", value: t.title)]
        if !t.album.isEmpty { c.queryItems?.append(.init(name: "album_name", value: t.album)) }
        if t.duration > 0 { c.queryItems?.append(.init(name: "duration", value: String(Int(t.duration)))) }
        var req = URLRequest(url: c.url!)
        req.setValue("RichPresence (personal use)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var lines: [(TimeInterval, String)] = []
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let synced = j["syncedLyrics"] as? String {
                let re = try! NSRegularExpression(pattern: "^\\[(\\d+):(\\d+(?:\\.\\d+)?)\\](.*)$")
                for raw in synced.split(separator: "\n") {
                    let s = String(raw)
                    guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                          let mm = Range(m.range(at: 1), in: s), let ss = Range(m.range(at: 2), in: s),
                          let tx = Range(m.range(at: 3), in: s) else { continue }
                    lines.append(((Double(s[mm]) ?? 0) * 60 + (Double(s[ss]) ?? 0),
                                  s[tx].trimmingCharacters(in: .whitespaces)))
                }
            }
            Task { @MainActor in
                self.lyricsCache[key] = lines.sorted { $0.0 < $1.0 }
                self.lyricsLoading.remove(key)
                if lines.isEmpty { self.say("No synced lyrics found for \(t.title)") }
            }
        }.resume()
    }

    func say(_ m: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(m)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
        UserDefaults.standard.set(log, forKey: "log")
    }

    // ------------------------------------------------ Discord
    func link(_ l: Link) {
        l.link()
        objectWillChange.send()
    }

    func unlink(_ l: Link) {
        l.unlink()
        updateAwake()
        push(force: true)
        objectWillChange.send()
    }

    // ------------------------------------------------ Apple Music
    func askForMusic() {
        MPMediaLibrary.requestAuthorization { status in
            Task { @MainActor in
                self.musicAllowed = status == .authorized
                self.refreshTrack()
            }
        }
    }

    private var appleTrack: Track?
    private var spotifyTrack: Track?

    func refreshTrack() {
        let p = MPMusicPlayerController.systemMusicPlayer
        appleTrack = nil
        if musicAllowed, p.playbackState == .playing, let item = p.nowPlayingItem, let title = item.title, !title.isEmpty {
            appleTrack = Track(title: title, artist: item.artist ?? "", album: item.albumTitle ?? "",
                               duration: item.playbackDuration, position: p.currentPlaybackTime)
        }
        setTrack()
    }

    /// Spotify is asked every 5 seconds (its API has no "song changed" notification).
    func refreshSpotify() {
        guard spotify.linked else {
            if spotifyTrack != nil { spotifyTrack = nil; setTrack() }
            return
        }
        Task {
            let t = await spotify.nowPlaying()
            spotifyTrack = t
            setTrack()
        }
    }

    /// Spotify wins when both are playing (it's on the account, Apple Music is only this phone).
    private func setTrack() {
        let t = spotifyTrack ?? appleTrack
        if t != track {
            if let t { say("Music (\(t.source)): \(t.artist) - \(t.title)") }
            lyricLine = nil
        }
        track = t
        push(force: false)
    }

    // ------------------------------------------------ games (from Shortcuts)
    func showGame(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if game != n { gameSince = Date(); say("Playing: \(n)") }
        game = n
        stayAwake(true)
        push(force: true)
    }

    /// From the multi-app automation: the same app arriving again means it closed.
    func toggleGame(_ raw: String?) {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        say("Automation passed in: \(name.isEmpty ? "nothing" : "\"\(name)\"")")
        guard !name.isEmpty else {
            say("No app name was passed in. Set the action's App field to Shortcut Input, or use one automation per game.")
            return
        }
        if game?.lowercased() == name.lowercased() { clearGame() } else { showGame(name) }
    }

    func clearGame() {
        guard game != nil else { return }
        say("Game closed")
        game = nil
        updateAwake()
        push(force: true)
    }

    /// iOS pauses apps in the background, which would drop the Discord connection and the status.
    /// While a game is showing, a silent sound (mixed with the game's own audio) keeps the app running.
    private func stayAwake(_ on: Bool) {
        if on {
            if bgTask == .invalid {
                bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                    MainActor.assumeIsolated { self?.endTask() }
                }
            }
            guard keepAlive == nil else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(data: Self.silentWav())
                p.numberOfLoops = -1
                p.volume = 0
                p.play()
                keepAlive = p
            } catch {
                say("Couldn't stay running in the background: \(error.localizedDescription)")
            }
        } else {
            keepAlive?.stop()
            keepAlive = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            endTask()
        }
    }

    private func endTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    /// One second of silence as a WAV file, built in memory.
    private static func silentWav() -> Data {
        let rate: UInt32 = 8000
        let bytes = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: Int(bytes)))
        return d
    }

    private func push(force: Bool) {
        let music = musicTarget

        // ---- game card
        if let g = game {
            let start = Int64(gameSince.timeIntervalSince1970 * 1000)
            gameLink.send("game|\(g)", force: force) { _ in
                // like the Windows card: "Playing <game>", with the game's App Store icon
                appIcon(for: g) { [weak self] icon in
                    guard let self, self.game == g else { return }
                    self.gameLink.bridge.update(withType: 0, name: g, display: 0, details: "on iPhone", state: nil,
                                                start: start, end: 0, image: icon, imageText: icon == nil ? nil : g)
                }
            }
        } else if music !== gameLink {
            gameLink.clear()
        }

        // ---- music card
        if music !== musicLink { musicLink.clear() }
        guard let target = music else { return }
        guard showMusic, let t = track else { target.clear(); return }
        let lyric = showLyrics ? lyricLine : nil
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let start = now - Int64(t.currentPosition * 1000)
        let end = t.duration > 0 ? start + Int64(t.duration * 1000) : 0
        target.send("\(t.artist)|\(t.title)|\(t.album)|\(lyric ?? "")", force: force) { bridge in
            let useArt: (@escaping (String?) -> Void) -> Void = { done in if let a = t.artUrl { done(a) } else { self.artwork(for: t, done: done) } }
            useArt { art in
                // like the Windows card: "Listening to <artist>", song title on the first line
                let artist = t.artist.isEmpty ? t.source : String(t.artist.prefix(128))
                bridge.update(withType: 2, name: artist, display: 0, details: String(t.title.prefix(128)),
                              state: lyric ?? (t.artist.isEmpty ? "Apple Music" : String("by \(t.artist)".prefix(128))),
                              start: start, end: end, image: art,
                              imageText: String((t.album.isEmpty ? t.title : "\(t.title) - \(t.album)").prefix(128)))
            }
        }
    }

    /// A game's icon from the App Store (Apple's public search), cached per name.
    private func appIcon(for name: String, done: @escaping (String?) -> Void) {
        let key = "app|\(name.lowercased())"
        if let hit = artCache[key] { done(hit.isEmpty ? nil : hit); return }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: name), .init(name: "entity", value: "software"),
                        .init(name: "limit", value: "5")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            var url: String?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = j["results"] as? [[String: Any]] {
                // prefer an exact name match, otherwise the top result
                let exact = results.first { ($0["trackName"] as? String)?.lowercased() == name.lowercased() }
                let pick = exact ?? results.first
                url = (pick?["artworkUrl512"] ?? pick?["artworkUrl100"]) as? String
            }
            Task { @MainActor in
                self.artCache[key] = url ?? ""
                done(url)
            }
        }.resume()
    }

    /// Album art from Apple's public search (Discord needs a web address, not the image itself).
    private func artwork(for t: Track, done: @escaping (String?) -> Void) {
        let key = "\(t.artist)|\(t.album)|\(t.title)"
        if let hit = artCache[key] { done(hit.isEmpty ? nil : hit); return }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(t.artist) \(t.album) \(t.title)"),
                        .init(name: "entity", value: "song"), .init(name: "limit", value: "1")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            var url: String?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let r = (j["results"] as? [[String: Any]])?.first, let a = r["artworkUrl100"] as? String {
                url = a.replacingOccurrences(of: "100x100bb", with: "512x512bb")
            }
            Task { @MainActor in
                self.artCache[key] = url ?? ""
                done(url)
            }
        }.resume()
    }
}
