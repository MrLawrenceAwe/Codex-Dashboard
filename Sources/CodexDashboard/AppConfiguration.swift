import Foundation

enum AppConfiguration {
    static let hostBundleIdentifier = "com.openai.codex"
    static let hostApplicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    static let devToolsHost = "127.0.0.1"
    static let devToolsPort = 47_832

    static let hostLaunchArguments = [
        "--remote-debugging-address=\(devToolsHost)",
        "--remote-debugging-port=\(devToolsPort)",
        "--remote-allow-origins=http://localhost",
    ]

    private static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)

    static let stateDatabaseURL = codexDirectory.appendingPathComponent("state_5.sqlite")
}
