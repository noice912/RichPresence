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
                Section("Discord") {
                    if let name = model.linkedName {
                        Label(model.connected ? "Linked as \(name)" : "Linked as \(name) (connecting...)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(green)
                        Button("Unlink", role: .destructive) { model.unlink() }
                    } else {
                        Text("Link your Discord account so the app can set your status.").foregroundStyle(.secondary)
                        Button { model.link() } label: {
                            Text(model.linking ? "Waiting for Discord..." : "Link Discord account").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(model.linking)
                    }
                }

                Section {
                    if model.musicAllowed {
                        Label("Apple Music access", systemImage: "checkmark.circle.fill").foregroundStyle(green)
                    } else {
                        Button("Allow Apple Music access") { model.askForMusic() }
                    }
                    Toggle("Show what I'm listening to", isOn: $model.showMusic)
                } header: {
                    Text("Apple Music")
                } footer: {
                    Text("iOS only lets apps see Apple Music, not other players or games. It updates while RichPresence is open or was used recently.")
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
                        }
                    } else {
                        Text("Nothing playing in Apple Music").foregroundStyle(.secondary)
                    }
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
