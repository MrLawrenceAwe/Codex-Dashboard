import Foundation

enum AppConfiguration {
    static let hostBundleIdentifier = "com.openai.codex"
    static let hostExecutableURL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
    static let devToolsHost = "127.0.0.1"
    static let devToolsPort = 47_832

    private static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)

    static let stateDatabaseURL = codexDirectory.appendingPathComponent("state_5.sqlite")
    static let activityDatabaseURL = codexDirectory.appendingPathComponent("logs_2.sqlite")
}
