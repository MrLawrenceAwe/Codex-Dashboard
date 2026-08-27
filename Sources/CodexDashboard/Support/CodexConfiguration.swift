import AppKit
import Foundation

enum CodexConfiguration {
    static let bundleIdentifier = "com.openai.codex"
    static let codexApplicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    static let codexExecutableURL = codexApplicationURL
        .appendingPathComponent("Contents/Resources/codex")
    static let devToolsAddress = "127.0.0.1"
    // Reuse the port of an already-running Codex renderer so restarting only the
    // dashboard does not orphan its connection. New Codex launches still receive
    // a random high port because DevTools does not authenticate loopback clients.
    static let devToolsPort = runningCodexDevToolsPort() ?? Int.random(in: 49_152...65_535)

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

    static func devToolsPort(inProcessArguments arguments: String) -> Int? {
        let prefix = "--remote-debugging-port="
        return arguments.split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix(prefix) })
            .flatMap { Int($0.dropFirst(prefix.count)) }
            .flatMap { (1...65_535).contains($0) ? $0 : nil }
    }

    private static func runningCodexDevToolsPort() -> Int? {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
        for application in applications {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-p", String(application.processIdentifier), "-o", "args="]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard
                process.terminationStatus == 0,
                let arguments = String(data: data, encoding: .utf8),
                let port = devToolsPort(inProcessArguments: arguments)
            else { continue }
            return port
        }
        return nil
    }
}
