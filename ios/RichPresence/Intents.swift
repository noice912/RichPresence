import AppIntents

/// "Show game on Discord": used from a Shortcuts automation like
/// "When Genshin Impact is opened -> Show game on Discord (Genshin Impact)".
struct ShowGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Show game on Discord"
    static var description = IntentDescription("Shows \"Playing <game>\" on your Discord status until the game is cleared.")
    static var openAppWhenRun = false

    @Parameter(title: "Game") var game: String

    static var parameterSummary: some ParameterSummary { Summary("Show \(\.$game) on Discord") }

    @MainActor
    func perform() async throws -> some IntentResult {
        Model.shared.showGame(game)
        return .result()
    }
}

/// "Clear game on Discord": for the matching "When <game> is closed" automation.
struct ClearGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Clear game on Discord"
    static var description = IntentDescription("Removes the game from your Discord status (your music comes back).")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Model.shared.clearGame()
        return .result()
    }
}

struct RichPresenceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowGameIntent(), phrases: ["Show my game on \(.applicationName)"],
                    shortTitle: "Show game", systemImageName: "gamecontroller")
        AppShortcut(intent: ClearGameIntent(), phrases: ["Clear my game on \(.applicationName)"],
                    shortTitle: "Clear game", systemImageName: "xmark.circle")
    }
}
