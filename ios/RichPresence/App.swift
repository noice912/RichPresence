import SwiftUI

@main
struct RichPresenceApp: App {
    @StateObject private var model = Model.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { p in if p == .active { model.refreshTrack() } }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    private let accent = Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255)
    private let green = Color(red: 0x3B / 255, green: 0xA5 / 255, blue: 0x5D / 255)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LinkRow(link: model.gameLink, what: "games", accent: accent, green: green)
                    LinkRow(link: model.musicLink, what: "music", accent: accent, green: green)
                } header: {
                    Text("Discord")
                } footer: {
                    Text("Discord shows one card per app, so games and music each have their own. Link both to show a game and a song at the same time. Until the music card is linked, music uses the game card when no game is showing.")
                }

                Section {
                    if model.musicAllowed {
                        Label("Apple Music access", systemImage: "checkmark.circle.fill").foregroundStyle(green)
                    } else {
                        Button("Allow Apple Music access") { model.askForMusic() }
                    }
                    Toggle("Show what I'm listening to", isOn: $model.showMusic)
                    Toggle("Show live lyrics", isOn: $model.showLyrics)
                    Toggle("Keep running in the background", isOn: $model.background)
                } header: {
                    Text("Apple Music")
                } footer: {
                    Text("iOS only lets apps see Apple Music, not other players. With \"Keep running in the background\" on, RichPresence plays a silent sound so iOS keeps it running and new songs show up without opening the app. It uses a little more battery.")
                }

                Section {
                    if let g = model.game {
                        Label("Playing \(g)", systemImage: "gamecontroller.fill").foregroundStyle(green)
                        Button("Clear game", role: .destructive) { model.clearGame() }
                    } else {
                        Text("No game showing").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Games")
                } footer: {
                    Text("iOS doesn't tell apps which game is open, so the Shortcuts app does it. In Shortcuts > Automation > + > App, pick a game and \"Is Opened\", choose Run Immediately, and add the action \"Show game on Discord\" with the game's name. Make a second one for \"Is Closed\" with \"Clear game on Discord\". A game replaces your music on Discord while you play.")
                }

                Section("Now playing") {
                    if let t = model.track {
                        VStack(alignment: .leading) {
                            Text(t.title).bold()
                            Text(t.artist).foregroundStyle(.secondary)
                            if let line = model.lyricLine {
                                Text(line).italic().foregroundStyle(accent).padding(.top, 2)
                            }
                        }
                    } else {
                        Text("Nothing playing in Apple Music").foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                }

                Section("Log") {
                    ForEach(Array(model.log.suffix(40).enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("RichPresence")
        }
    }
}

/// Link / unlink one Discord card (each is its own Discord app, so each is linked once).
struct LinkRow: View {
    @EnvironmentObject var model: Model
    @ObservedObject var link: Link
    let what: String
    let accent: Color
    let green: Color

    var body: some View {
        if let name = link.name {
            HStack {
                Label("\(link.label): \(name)\(link.connected ? "" : " (connecting...)")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(green)
                Spacer()
                Button("Unlink", role: .destructive) { model.unlink(link) }.buttonStyle(.borderless)
            }
        } else {
            Button { model.link(link) } label: {
                Text(link.linking ? "Waiting for Discord..." : "Link the \(what) card").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(accent).disabled(link.linking)
        }
    }
}
