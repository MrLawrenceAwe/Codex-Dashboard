import AppKit
import Darwin

@MainActor
final class ManagedChatController {
    static let shared = ManagedChatController()
    let workspace: ManagedChatWorkspace
    private(set) var isBusy = false
    private var launchingProcess: Process?

    init(workspace: ManagedChatWorkspace = ManagedChatWorkspace()) { self.workspace = workspace }

    func openAll(accounts: AccountCoordinator) async throws {
        guard !isBusy else { throw ManagedChatError.busy }
        isBusy = true
        defer { isBusy = false }
        let lease = try await ManagedChatLease.acquire(workspace.root)
        defer { withExtendedLifetime(lease) {} }
        await accounts.refreshState()
        guard !accounts.savedAccounts.isEmpty else { throw ManagedChatError.noAccounts }
        try await ensureServer(accounts: accounts)
        for account in accounts.savedAccounts { try await openPreparedWindow(account.id) }
    }

    func open(_ accountID: UUID, accounts: AccountCoordinator) async throws {
        guard !isBusy else { throw ManagedChatError.busy }
        isBusy = true
        defer { isBusy = false }
        let lease = try await ManagedChatLease.acquire(workspace.root)
        defer { withExtendedLifetime(lease) {} }
        await accounts.refreshState()
        try await ensureServer(accounts: accounts)
        try await openPreparedWindow(accountID)
    }

    func recover(accounts: AccountCoordinator, interrupt: Bool = false) async throws {
        guard !isBusy else { throw ManagedChatError.busy }
        isBusy = true
        defer { isBusy = false }
        let lease = try await ManagedChatLease.acquire(workspace.root)
        defer { withExtendedLifetime(lease) {} }
        await accounts.refreshState()
        if workspace.brokerPID != nil {
            let rpc = try control()
            if interrupt { _ = try await rpc.request("dashboard/interrupt") }
            let status = try await rpc.request("dashboard/status")
            struct Status: Decodable { struct Value: Decodable { let safeToStop: Bool }; let result: Value }
            guard try JSONDecoder().decode(Status.self, from: status).result.safeToStop else { throw ManagedChatError.busy }
        }
        let openIDs = try await closeManagedWindows()
        if let pid = workspace.brokerPID {
            Darwin.kill(pid, SIGTERM)
            for _ in 0..<150 where workspace.brokerPID != nil { try await Task.sleep(for: .milliseconds(100)) }
            guard workspace.brokerPID == nil else { throw ManagedChatError.ownership }
        }
        if let pid = workspace.ownerPID {
            // Only explicit recovery may stop an orphan. Verify its private home
            // in memory; never print the environment, which can contain tokens.
            let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["eww", "-p", String(pid), "-o", "command="], timeout: 5)
            let command = String(decoding: result.standardOutput, as: UTF8.self)
            guard command.contains("CODEX_HOME=" + workspace.server.appendingPathComponent("owner").path),
                  command.contains("CODEX_SQLITE_HOME=" + workspace.history.path) else { throw ManagedChatError.ownership }
            Darwin.kill(pid, SIGTERM)
            for _ in 0..<150 where workspace.ownerPID != nil { try await Task.sleep(for: .milliseconds(100)) }
            guard workspace.ownerPID == nil else { throw ManagedChatError.ownership }
        }
        try await ensureServer(accounts: accounts)
        for id in openIDs { try await openPreparedWindow(id) }
    }

    private func control() throws -> ManagedChatRPC {
        guard let endpoint = try workspace.endpoints(ready: false).first else { throw ManagedChatError.needsRecovery }
        return ManagedChatRPC(endpoint: endpoint)
    }

    private func ensureServer(accounts: AccountCoordinator) async throws {
        if workspace.brokerPID != nil {
            let data = try await control().request("dashboard/status")
            struct Status: Decodable { struct Value: Decodable { let healthy: Bool }; let result: Value }
            guard try JSONDecoder().decode(Status.self, from: data).result.healthy else { throw ManagedChatError.needsRecovery }
            try await seedProjects()
            return
        }
        guard workspace.ownerPID == nil else { throw ManagedChatError.needsRecovery }
        let manager = FileManager.default
        for directory in [workspace.root, workspace.server, workspace.history, workspace.windows] {
            if manager.fileExists(atPath: directory.path) {
                guard try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw ManagedChatError.ownership
                }
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var windows: [ChatHandoffServer.Window] = []
        for account in accounts.savedAccounts {
            guard let identity = account.codexAccountID else { continue }
            let profile = workspace.profile(account.id)
            let credential = profile.isInitialized ? nil : try await accounts.credentialForSeparateWindow(account.id)
            try profile.prepare(credential: credential, expectedAccountID: identity)
            windows.append(.init(id: account.id.uuidString.lowercased(), home: profile.codexHome,
                                 accountIdentifier: identity, token: UUID().uuidString))
        }
        guard !windows.isEmpty else { throw ManagedChatError.noAccounts }
        let configuration = ChatHandoffServer.Configuration(root: workspace.server, historyHome: workspace.history,
                                                            executable: CodexConfiguration.codexExecutableURL, windows: windows)
        try JSONEncoder().encode(configuration).write(to: workspace.configuration, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.configuration.path)
        for name in ["ready.json", "connections.json"] {
            let file = workspace.server.appendingPathComponent(name)
            if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--shared-chat-server", workspace.configuration.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        launchingProcess = process
        for _ in 0..<400 {
            guard process.isRunning else { throw ManagedChatError.startup }
            if manager.fileExists(atPath: workspace.server.appendingPathComponent("ready.json").path) {
                _ = try await control().request("dashboard/status")
                try await seedProjects()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // The child owns the lock and its PID file. Leave uncertain work in place
        // for explicit recovery rather than spawning another writer.
        throw ManagedChatError.startup
    }

    private func seedProjects() async throws {
        let marker = workspace.root.appendingPathComponent("projects-seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let database = CodexConfiguration.stateDatabaseURL
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-readonly", "-json", database.path, "SELECT projects.id, projects.name, project_roots.path FROM projects JOIN project_roots ON project_roots.project_id=projects.id ORDER BY projects.position, project_roots.position;"], timeout: 5)
        guard result.terminationStatus == 0 else { throw ManagedChatError.startup }
        struct Row: Decodable { let id: String; let name: String; let path: String }
        let rows = result.standardOutput.isEmpty ? [] : try JSONDecoder().decode([Row].self, from: result.standardOutput)
        let grouped = Dictionary(grouping: rows, by: \.id)
        let rpc = try control()
        for id in rows.map(\.id).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            guard let roots = grouped[id], let first = roots.first else { continue }
            _ = try await rpc.request("project/create", params: ["name": first.name,
                "idempotencyKey": "managed-seed-" + id, "metadata": ["dashboard-source-project": id],
                "roots": roots.map { ["path": $0.path] }])
        }
        try Data().write(to: marker, options: .atomic)
    }

    private func openPreparedWindow(_ accountID: UUID) async throws {
        let profile = workspace.profile(accountID)
        let environment = try workspace.environment(accountID)
        if let app = applications(profile).first {
            try await AccountWindowPresenter().present(app, profile: profile, environment: environment)
            return
        }
        let launch = NSWorkspace.OpenConfiguration()
        launch.createsNewApplicationInstance = true
        launch.arguments = profile.arguments + CodexConfiguration.debugArguments(port: CodexConfiguration.randomDevToolsPort())
        launch.environment = environment
        launch.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: CodexConfiguration.codexApplicationURL, configuration: launch)
        try await AccountWindowPresenter().present(app, profile: profile, environment: environment)
    }

    private func applications(_ profile: AccountWindowProfile) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier).filter {
            CodexConfiguration.processArguments(for: $0.processIdentifier).map(profile.matches) == true
        }
    }

    private func closeManagedWindows() async throws -> [UUID] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: workspace.windows, includingPropertiesForKeys: nil)) ?? []
        var open: [UUID] = []
        var targets: [NSRunningApplication] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let apps = applications(workspace.profile(id))
            if !apps.isEmpty { open.append(id); targets += apps }
        }
        targets.forEach { _ = $0.terminate() }
        for _ in 0..<150 where !targets.allSatisfy(\.isTerminated) { try await Task.sleep(for: .milliseconds(100)) }
        guard targets.allSatisfy(\.isTerminated) else { throw ManagedChatError.busy }
        return open
    }
}
