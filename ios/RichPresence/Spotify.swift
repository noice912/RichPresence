import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Reads what's playing on the person's Spotify account (any device) through Spotify's Web API.
/// Sign-in is Spotify's PKCE flow, so no secret is kept in the app.
@MainActor
final class Spotify: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let clientId = "76bb0776673e40e8b22492533f94b1b9"
    static let redirect = "richpresence://spotify-callback"
    private static let scopes = "user-read-currently-playing user-read-playback-state"

    @Published var linked = Keychain.get("spotify_refresh") != nil
    @Published var linking = false
    private var access: String? = Keychain.get("spotify_access")
    private var expires = UserDefaults.standard.object(forKey: "spotify_expires") as? Date ?? .distantPast
    private var session: ASWebAuthenticationSession?
    private let say: (String) -> Void

    init(say: @escaping (String) -> Void) { self.say = say }

    // ------------------------------------------------ sign-in
    func link() {
        let verifier = Self.random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [.init(name: "client_id", value: Self.clientId), .init(name: "response_type", value: "code"),
                        .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
                        .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge)]
        linking = true
        session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "richpresence") { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                self.linking = false
                guard let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else {
                    if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.say("Spotify: linking failed (\(error.localizedDescription))")
                    }
                    return
                }
                await self.token(["grant_type": "authorization_code", "code": code,
                                  "redirect_uri": Self.redirect, "code_verifier": verifier])
                if self.linked { self.say("Spotify linked.") }
            }
        }
        session?.presentationContextProvider = self
        session?.start()
    }

    func unlink() {
        Keychain.set(nil, for: "spotify_access")
        Keychain.set(nil, for: "spotify_refresh")
        access = nil
        linked = false
        say("Spotify unlinked.")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private func token(_ form: [String: String]) async {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var f = form
        f["client_id"] = Self.clientId
        req.httpBody = f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            say("Spotify: couldn't reach Spotify to sign in")
            return
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let a = j["access_token"] as? String else {
            say("Spotify: sign-in refused (\(j["error_description"] as? String ?? j["error"] as? String ?? "unknown"))")
            if (j["error"] as? String) == "invalid_grant" { unlink() }
            return
        }
        access = a
        Keychain.set(a, for: "spotify_access")
        if let r = j["refresh_token"] as? String { Keychain.set(r, for: "spotify_refresh") }
        expires = Date().addingTimeInterval(TimeInterval(j["expires_in"] as? Int ?? 3600) - 60)
        UserDefaults.standard.set(expires, forKey: "spotify_expires")
        linked = true
    }

    // ------------------------------------------------ now playing
    /// The playing song, or nil when nothing is playing (or it's a podcast/ad).
    func nowPlaying() async -> Track? {
        guard linked else { return nil }
        if access == nil || Date() > expires, let r = Keychain.get("spotify_refresh") {
            await token(["grant_type": "refresh_token", "refresh_token": r])
        }
        guard let access else { return nil }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { expires = .distantPast; return nil }
        guard code == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["is_playing"] as? Bool == true, let item = j["item"] as? [String: Any],
              let title = item["name"] as? String else { return nil }
        let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
        let album = item["album"] as? [String: Any]
        let art = (album?["images"] as? [[String: Any]])?.first?["url"] as? String
        return Track(title: title, artist: artists, album: album?["name"] as? String ?? "",
                     duration: Double(item["duration_ms"] as? Int ?? 0) / 1000,
                     position: Double(j["progress_ms"] as? Int ?? 0) / 1000,
                     at: Date(), artUrl: art, source: "Spotify")
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
