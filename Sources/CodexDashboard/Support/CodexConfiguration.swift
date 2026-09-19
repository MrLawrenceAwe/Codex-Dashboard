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
    private static let devToolsPortStorage = DevToolsPortStorage(
        port: runningCodexDevToolsPort() ?? randomDevToolsPort()
    )

    static var devToolsPort: Int {
        devToolsPortStorage.port
    }

    static var launchArguments: [String] {
        [
            "--remote-debugging-address=\(devToolsAddress)",
            "--remote-debugging-port=\(devToolsPort)",
            "--remote-allow-origins=http://localhost",
        ]
    }

    // A port that worked for a prior Codex process is not necessarily free once
    // that process has exited. Rotate it for each launch; the runtime retries a
    // failed renderer startup once with another port.
    static func selectFreshDevToolsPortForLaunch() {
        devToolsPortStorage.selectFreshPort(using: randomDevToolsPort)
    }

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

    private static func randomDevToolsPort(excluding: Int? = nil) -> Int {
        var port: Int
        repeat {
            port = Int.random(in: 49_152...65_535)
        } while port == excluding
        return port
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

private final class DevToolsPortStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var selectedPort: Int

    init(port: Int) {
        selectedPort = port
    }

    var port: Int {
        lock.withLock { selectedPort }
    }

    func selectFreshPort(using generator: (Int?) -> Int) {
        lock.withLock {
            selectedPort = generator(selectedPort)
        }
    }
}
