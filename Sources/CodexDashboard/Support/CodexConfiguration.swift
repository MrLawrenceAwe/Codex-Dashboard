import Foundation

enum CodexConfiguration {
    static let bundleIdentifier = "com.openai.codex"
    static let codexApplicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    static let devToolsAddress = "127.0.0.1"
    static let devToolsPort = 47_832

    static let launchArguments = [
        "--remote-debugging-address=\(devToolsAddress)",
        "--remote-debugging-port=\(devToolsPort)",
        "--remote-allow-origins=http://localhost",
    ]

    private static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)

    private static let applicationSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Codex Dashboard", isDirectory: true)

    static let stateDatabaseURL = codexDirectory.appendingPathComponent("state_5.sqlite")
    static let globalStateURL = codexDirectory.appendingPathComponent(".codex-global-state.json")
    static let authenticationURL = codexDirectory.appendingPathComponent("auth.json")
    static let accountMetadataURL = applicationSupportDirectory.appendingPathComponent("accounts.json")

    static var installedVersion: String? {
        guard let bundle = Bundle(url: codexApplicationURL) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
