import Foundation

enum CodexConfiguration {
    static let bundleIdentifier = "com.openai.codex"
    static let codexApplicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    static let codexExecutableURL = codexApplicationURL
        .appendingPathComponent("Contents/Resources/codex")
    static let devToolsAddress = "127.0.0.1"
    // DevTools does not authenticate loopback clients. A per-launch high port avoids
    // leaving a predictable, permanently-scanned local debugging endpoint.
    static let devToolsPort = Int.random(in: 49_152...65_535)

    static let launchArguments = [
        "--remote-debugging-address=\(devToolsAddress)",
        "--remote-debugging-port=\(devToolsPort)",
        "--remote-allow-origins=http://localhost",
    ]

    static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)

    private static let applicationSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Codex Dashboard", isDirectory: true)

    static let stateDatabaseURL = codexDirectory.appendingPathComponent("state_5.sqlite")
    static let globalStateURL = codexDirectory.appendingPathComponent(".codex-global-state.json")
    static let authenticationURL = codexDirectory.appendingPathComponent("auth.json")
    static let accountMetadataURL = applicationSupportDirectory.appendingPathComponent("accounts.json")
    static let accountUsageCacheURL = applicationSupportDirectory
        .appendingPathComponent("account-usage.json")

    static var installedVersion: String? {
        guard let bundle = Bundle(url: codexApplicationURL) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
