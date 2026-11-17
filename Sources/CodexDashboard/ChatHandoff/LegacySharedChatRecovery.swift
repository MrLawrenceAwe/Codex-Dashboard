import Darwin
import Foundation

/// Retires the old login-session redirect without modifying history or credentials.
struct LegacySharedChatRecovery {
    let root: URL
    let readEnvironment: (String) throws -> String
    let unsetEnvironment: (String) throws -> Void
    let processIsAlive: (pid_t) -> Bool
    let processArguments: (pid_t) -> String?

    init(
        root: URL = CodexConfiguration.dashboardSupportDirectory().appendingPathComponent("shared-chat"),
        readEnvironment: @escaping (String) throws -> String = { try Self.launchctl(["getenv", $0]) },
        unsetEnvironment: @escaping (String) throws -> Void = { _ = try Self.launchctl(["unsetenv", $0]) },
        processIsAlive: @escaping (pid_t) -> Bool = { Darwin.kill($0, 0) == 0 || errno == EPERM },
        processArguments: @escaping (pid_t) -> String? = CodexConfiguration.processArguments
    ) {
        self.root = root
        self.readEnvironment = readEnvironment
        self.unsetEnvironment = unsetEnvironment
        self.processIsAlive = processIsAlive
        self.processArguments = processArguments
    }

    @discardableResult
    func recover() throws -> URL? {
        let manager = FileManager.default
        let names = ["enabled", "activate-when-idle", "ready.json", "pid", "owner-pid",
                     "previous-ws-url", "previous-force-cli", "configuration.json"]
        var files = names.map { root.appendingPathComponent($0) }.filter { manager.fileExists(atPath: $0.path) }
        // Retire the old merge ledger as well, so shared-backend tombstones
        // cannot be applied to independent account windows on the next launch.
        if !files.isEmpty {
            let ledger = root.deletingLastPathComponent().appendingPathComponent("shared-projects.json")
            if manager.fileExists(atPath: ledger.path) { files.insert(ledger, at: 0) }
        }
        for file in files {
            guard try manager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        guard !files.isEmpty else { return nil }
        // A native writer must never be launched beside an old shared writer.
        for name in ["pid", "owner-pid"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
                  processIsAlive(pid) else { continue }
            guard let arguments = processArguments(pid) else { throw ChatHandoffError.unsafeOwner }
            let isBroker = arguments.contains("--shared-chat-server " + root.appendingPathComponent("configuration.json").path)
            let isWriter = arguments.contains("/codex") && arguments.contains("app-server")
            guard !isBroker && !isWriter else { throw ChatHandoffError.unsafeOwner }
        }

        let archive = root.deletingLastPathComponent().appendingPathComponent("recovery")
            .appendingPathComponent("retired-shared-routing-" + UUID().uuidString)
        try manager.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in files {
            let copy = archive.appendingPathComponent(file.lastPathComponent)
            try manager.copyItem(at: file, to: copy)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        }

        let saved = (try? Data(contentsOf: root.appendingPathComponent("ready.json")))
            .flatMap { try? JSONDecoder().decode([ChatHandoffServer.Endpoint].self, from: $0) } ?? []
        let address = try readEnvironment("CODEX_APP_SERVER_WS_URL")
        let ownsAddress = saved.contains { $0.url == address }
            || (address == "ws://127.0.0.1:1" && manager.fileExists(atPath: root.appendingPathComponent("enabled").path))
        if ownsAddress { try unsetEnvironment("CODEX_APP_SERVER_WS_URL") }
        // Leave unrelated app-server configurations alone, including their flags.
        if (ownsAddress || address.isEmpty),
           manager.fileExists(atPath: root.appendingPathComponent("previous-force-cli").path),
           try readEnvironment("CODEX_APP_SERVER_FORCE_CLI") == "0" {
            try unsetEnvironment("CODEX_APP_SERVER_FORCE_CLI")
        }
        for file in files { try manager.removeItem(at: file) }
        return archive
    }

    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || arguments.first == "getenv" else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
