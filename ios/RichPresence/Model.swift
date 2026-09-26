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
}

@MainActor
final class Model: ObservableObject {
    /// One shared instance: the screen and the Shortcuts actions both use it.
    static let shared = Model()

    @Published var game: String?
    private var gameSince = Date()
    private var keepAlive: AVAudioPlayer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    @Published var linkedName: String? = UserDefaults.standard.string(forKey: "user")
    @Published var connected = false
    @Published var linking = false
    @Published var musicAllowed = MPMediaLibrary.authorizationStatus() == .authorized
    @Published var showMusic = UserDefaults.standard.object(forKey: "show_music") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMusic, forKey: "show_music"); push(force: true) }
    }
    @Published var track: Track?
    @Published var log: [String] = []

    private let discord: DiscordBridge
    private var pump: Timer?
    private var poll: Timer?
    private var artCache: [String: String] = [:]
    private var lastSent: String?
    private var sentAt = Date.distantPast

    private init() {
        let id = UInt64(Bundle.main.object(forInfoDictionaryKey: "DiscordAppId") as? String ?? "") ?? 0
        discord = DiscordBridge(appId: id)
        discord.onLog = { [weak self] m in self?.say(m) }
        discord.onTokens = { [weak self] access, refresh, expiresIn in
            Keychain.set(access, for: "access")
            Keychain.set(refresh, for: "refresh")
            UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(expiresIn)), forKey: "expires_at")
            if self?.linking == true { self?.say("Discord account linked.") }
            self?.linking = false
        }
        discord.onReady = { [weak self] name in
            guard let self else { return }
            self.connected = true
            self.linkedName = name
            UserDefaults.standard.set(name, forKey: "user")
            self.say("Signed in to Discord as \(name)")
            self.lastSent = nil
            self.push(force: true)
        }
        discord.onDisconnected = { [weak self] reason in
            self?.connected = false
            if !reason.isEmpty { self?.say("Discord disconnected: \(reason)") }
        }
        pump = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.discord.runCallbacks() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrack() }
        }
        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()
        for n in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            NotificationCenter.default.addObserver(forName: n, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTrack() }
            }
        }
        signInSaved()
        refreshTrack()
    }

    func say(_ m: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(m)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // ------------------------------------------------ Discord
    private func signInSaved() {
        guard let refresh = Keychain.get("refresh") else { return }
        let expires = UserDefaults.standard.object(forKey: "expires_at") as? Date ?? .distantPast
        if let access = Keychain.get("access"), expires.timeIntervalSinceNow > 86_400 {
            discord.useAccessToken(access)
        } else {
            discord.refresh(withToken: refresh)
        }
    }

    func link() {
        linking = true
        say("Opening Discord to link your account...")
        discord.authorize()
    }

    func unlink() {
        Keychain.set(nil, for: "access")
        Keychain.set(nil, for: "refresh")
        UserDefaults.standard.removeObject(forKey: "user")
        discord.disconnect()
        linkedName = nil
        connected = false
        say("Discord account unlinked.")
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

    func refreshTrack() {
        let p = MPMusicPlayerController.systemMusicPlayer
        var t: Track?
        if musicAllowed, p.playbackState == .playing, let item = p.nowPlayingItem, let title = item.title, !title.isEmpty {
            t = Track(title: title, artist: item.artist ?? "", album: item.albumTitle ?? "",
                      duration: item.playbackDuration, position: p.currentPlaybackTime)
        }
        if t?.title != track?.title || t?.artist != track?.artist {
            if let t { say("Music: \(t.artist) - \(t.title)") }
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

    func clearGame() {
        guard game != nil else { return }
        say("Game closed")
        game = nil
        stayAwake(false)
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
        guard connected else { return }
        if let g = game {
            let sig = "game|\(g)"
            if !force && sig == lastSent && Date().timeIntervalSince(sentAt) < 30 { return }
            lastSent = sig
            sentAt = Date()
            // like the Windows card: "Playing <game>", with the game's App Store icon
            let start = Int64(gameSince.timeIntervalSince1970 * 1000)
            appIcon(for: g) { [weak self] icon in
                guard let self, self.game == g else { return }
                self.discord.update(withType: 0, name: g, display: 0, details: "on iPhone", state: nil,
                                    start: start, end: 0, image: icon, imageText: icon == nil ? nil : g)
            }
            return
        }
        guard showMusic, let t = track else {
            if lastSent != nil { discord.clear(); lastSent = nil }
            return
        }
        let sig = "\(t.artist)|\(t.title)|\(t.album)"
        if !force && sig == lastSent && Date().timeIntervalSince(sentAt) < 30 { return }
        lastSent = sig
        sentAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let start = now - Int64(t.position * 1000)
        let end = t.duration > 0 ? start + Int64(t.duration * 1000) : 0
        artwork(for: t) { [weak self] art in
            // like the Windows card: "Listening to <artist>", song title on the first line
            let artist = t.artist.isEmpty ? "Apple Music" : String(t.artist.prefix(128))
            self?.discord.update(withType: 2, name: artist, display: 1, details: String(t.title.prefix(128)),
                                 state: artist,
                                 start: start, end: end, image: art,
                                 imageText: String((t.album.isEmpty ? t.title : "\(t.title) - \(t.album)").prefix(128)))
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
