import Foundation

/// One Discord application linked to the person's account = one card on their status.
/// RichPresence uses two: games on "RichPresence Mobile", music on "RichPresence Music".
@MainActor
final class Link: ObservableObject {
    let label: String
    let bridge: DiscordBridge
    @Published var name: String?
    @Published var connected = false
    @Published var linking = false
    var lastSent: String?
    var sentAt = Date.distantPast
    var onReady: (() -> Void)?

    private let prefix: String
    private let say: (String) -> Void

    /// `prefix` keeps each link's saved sign-in apart ("" is the original game link, so it keeps working).
    init(label: String, appId: UInt64, prefix: String, say: @escaping (String) -> Void) {
        self.label = label
        self.prefix = prefix
        self.say = say
        bridge = DiscordBridge(appId: appId)
        name = UserDefaults.standard.string(forKey: prefix + "user")
        bridge.onLog = { [weak self] m in self?.say("\(label): \(m)") }
        bridge.onTokens = { [weak self] access, refresh, expiresIn in
            guard let self else { return }
            Keychain.set(access, for: prefix + "access")
            Keychain.set(refresh, for: prefix + "refresh")
            UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(expiresIn)), forKey: prefix + "expires_at")
            if self.linking { self.say("\(label): Discord account linked.") }
            self.linking = false
        }
        bridge.onReady = { [weak self] display in
            guard let self else { return }
            self.connected = true
            self.name = display
            UserDefaults.standard.set(display, forKey: prefix + "user")
            self.say("\(label): signed in as \(display)")
            self.lastSent = nil
            self.onReady?()
        }
        bridge.onDisconnected = { [weak self] reason in
            self?.connected = false
            if !reason.isEmpty { self?.say("\(label): disconnected (\(reason))") }
        }
    }

    var hasSignIn: Bool { Keychain.get(prefix + "refresh") != nil }

    func signInSaved() {
        guard let refresh = Keychain.get(prefix + "refresh") else { return }
        let expires = UserDefaults.standard.object(forKey: prefix + "expires_at") as? Date ?? .distantPast
        if let access = Keychain.get(prefix + "access"), expires.timeIntervalSinceNow > 86_400 {
            bridge.useAccessToken(access)
        } else {
            bridge.refresh(withToken: refresh)
        }
    }

    func link() {
        linking = true
        say("\(label): opening Discord to link your account...")
        bridge.authorize()
    }

    func unlink() {
        Keychain.set(nil, for: prefix + "access")
        Keychain.set(nil, for: prefix + "refresh")
        UserDefaults.standard.removeObject(forKey: prefix + "user")
        bridge.disconnect()
        name = nil
        connected = false
        lastSent = nil
        say("\(label): unlinked.")
    }

    /// Sends when the card changed (or every 30 s to keep it fresh). Returns whether it sent.
    @discardableResult
    func send(_ sig: String, force: Bool, _ update: (DiscordBridge) -> Void) -> Bool {
        guard connected else { return false }
        if !force && sig == lastSent && Date().timeIntervalSince(sentAt) < 30 { return false }
        lastSent = sig
        sentAt = Date()
        update(bridge)
        return true
    }

    func clear() {
        guard connected, lastSent != nil else { return }
        bridge.clear()
        lastSent = nil
    }
}
