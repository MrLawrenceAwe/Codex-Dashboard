import AppKit
import Foundation
import Darwin

/// Persistent launch contract. Missing/unhealthy endpoints fail closed rather
/// than allowing a desktop window to fall back to its own history writer.
enum ChatHandoffService {
    static var root: URL { CodexConfiguration.dashboardSupportDirectory().appendingPathComponent("shared-chat") }
    static var isRunning: Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8),
              let pid = pid_t(text), Darwin.kill(pid, 0) == 0,
              let args = CodexConfiguration.processArguments(for: pid) else { return false }
        return args.contains("--shared-chat-server " + configurationURL.path)
    }
    private static var historyOwnerIsRunning: Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("owner-pid"), encoding: .utf8),
              let pid = pid_t(text), Darwin.kill(pid, 0) == 0,
              let command = CodexConfiguration.processArguments(for: pid) else { return false }
        return command.contains("CodexCLI.app/Contents/MacOS/codex") && command.contains("app-server")
    }
    static var activationRequested: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("activate-when-idle").path) }

    static func requestActivationWhenIdle() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: root.appendingPathComponent("activate-when-idle"), options: .atomic)
    }

    static func consumeActivationRequest() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("activate-when-idle"))
    }

    static var configurationURL: URL { root.appendingPathComponent("configuration.json") }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("enabled").path) }
    static var supportsAccountSwitch: Bool {
        isRunning && endpoints.contains { $0.id == "main" && $0.supportsAccountSwitch == true }
    }

    private static var endpoints: [ChatHandoffServer.Endpoint] {
        let ready = root.appendingPathComponent("ready.json")
        return (try? JSONDecoder().decode([ChatHandoffServer.Endpoint].self, from: Data(contentsOf: ready))) ?? []
    }

    static func permitsAccountSwitch(to accountIdentifier: String) -> Bool {
        guard supportsAccountSwitch, let configuration = try? loadConfiguration() else { return false }
        return configuration.windows.contains { $0.accountIdentifier == accountIdentifier }
    }

    static func prepareMainWindowForAccountSwitch() throws {
        guard supportsAccountSwitch else { throw ChatHandoffError.disconnected }
        try SharedChatProjectAliases.prepare(configuration: loadConfiguration(), catalog: SharedProjectCatalog(), mainOnly: true)
    }

    private static func loadConfiguration() throws -> ChatHandoffServer.Configuration {
        try JSONDecoder().decode(ChatHandoffServer.Configuration.self, from: Data(contentsOf: configurationURL))
    }

    static func environment(windowID: String) -> [String: String] {
        guard isEnabled else { return [:] }
        return ["CODEX_APP_SERVER_WS_URL": endpoints.first(where: { $0.id == windowID })?.url ?? "ws://127.0.0.1:1",
                "CODEX_APP_SERVER_FORCE_CLI": "0", "CODEX_APP_SERVER_USE_LOCAL_DAEMON": "0"]
    }

    enum ActivationOutcome { case enabled, waitingForIdle, failed }

    @MainActor
    static func enable(main: AppCoordinator, windows: AccountWindowDashboards?) async -> ActivationOutcome {
        let updatingServer = isRunning
        guard !updatingServer || !supportsAccountSwitch else {
            main.accounts.setStatusMessage("Shared chats are already enabled.")
            return .enabled
        }
        let coordinators = [main] + (windows?.entries.values.map(\.coordinator) ?? [])
        guard coordinators.allSatisfy({ !$0.isPerformingAction }) else { return .waitingForIdle }
        for coordinator in coordinators { coordinator.isPerformingAction = true }
        defer { for coordinator in coordinators { coordinator.isPerformingAction = false } }
        let previouslyEnabled = isEnabled
        var changedEnvironment = false
        do {
            if !isRunning && historyOwnerIsRunning { throw ChatHandoffError.unsafeOwner }
            for coordinator in coordinators {
                await coordinator.cancelSynchronization()
                _ = try await coordinator.refreshThreadState()
                guard !coordinator.threads.contains(where: { $0.runState == .running }) else { throw CodexAccountError.activeTasks }
            }
            let mainCredential = try Data(contentsOf: CodexConfiguration.authenticationURL)
            guard let identity = AccountIdentityDecoder.identity(in: mainCredential) else { throw ChatHandoffError.identity }
            var configured = [ChatHandoffServer.Window(id: "main", home: CodexConfiguration.codexDirectory,
                accountIdentifier: identity.identifier, token: UUID().uuidString)]
            for account in main.accounts.savedAccounts {
                guard let expected = account.codexAccountID else { continue }
                let profile = AccountWindowProfile(accountID: account.id)
                let database = profile.codexHome.appendingPathComponent("state_5.sqlite")
                if FileManager.default.fileExists(atPath: database.path) {
                    let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                        arguments: ["-readonly", database.path, "SELECT count(*) FROM threads;"], timeout: 10)
                    guard result.terminationStatus == 0,
                          let count = Int(String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ChatHandoffError.unsafeOwner }
                    guard count == 0 else { throw ChatHandoffError.independentHistory }
                }
                let credential = profile.isInitialized ? nil : try await main.accounts.credentialForSeparateWindow(account.id)
                try profile.prepare(credential: credential, expectedAccountID: expected)
                guard let data = try? Data(contentsOf: profile.codexHome.appendingPathComponent("auth.json")),
                      AccountIdentityDecoder.identity(in: data)?.identifier == expected else { throw ChatHandoffError.identity }
                configured.append(.init(id: account.id.uuidString.lowercased(), home: profile.codexHome,
                    accountIdentifier: expected, token: UUID().uuidString))
            }
            let configuration = ChatHandoffServer.Configuration(root: root, historyHome: CodexConfiguration.codexDirectory,
                executable: CodexConfiguration.codexExecutableURL, windows: configured)
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier)
            guard applications.allSatisfy({ application in
                guard let args = CodexConfiguration.processArguments(for: application.processIdentifier) else { return false }
                return CodexConfiguration.isMainApplicationArguments(args) || main.accounts.savedAccounts.contains {
                    AccountWindowProfile(accountID: $0.id).matches(processArguments: args)
                }
            }) else { throw ChatHandoffError.unsafeOwner }
            let ledger = CodexConfiguration.dashboardSupportDirectory().appendingPathComponent("shared-projects.json")
            let catalog = try fm.fileExists(atPath: ledger.path)
                ? JSONDecoder().decode(SharedProjectCatalog.self, from: Data(contentsOf: ledger))
                : SharedProjectCatalog()
            // Validate before closing Codex and write only after its state has flushed.
            try SharedChatProjectAliases.prepare(configuration: configuration, catalog: catalog, validateOnly: true)
            // Capture descendants before quitting; adopting an orphaned native
            // app-server would create a second writer. Never force-kill a chat.
            let descendants = try processDescendants(of: Set(applications.map(\.processIdentifier)))
            let profiles = applications.compactMap { application -> AccountWindowProfile? in
                guard let args = CodexConfiguration.processArguments(for: application.processIdentifier) else { return nil }
                return main.accounts.savedAccounts.map { AccountWindowProfile(accountID: $0.id) }.first { $0.matches(processArguments: args) }
            }
            // Finder/Dock launches must also connect to the single writer. The
            // launchd override lasts for this login session; after a reboot a
            // dead broker never resumes automatically beside a native writer.
            if !previouslyEnabled {
                let previous = try launchEnvironment(["getenv", "CODEX_APP_SERVER_WS_URL"])
                try Data(previous.utf8).write(to: root.appendingPathComponent("previous-ws-url"), options: .atomic)
                let forceCLI = try launchEnvironment(["getenv", "CODEX_APP_SERVER_FORCE_CLI"])
                try Data(forceCLI.utf8).write(to: root.appendingPathComponent("previous-force-cli"), options: .atomic)
            }
            changedEnvironment = true
            _ = try launchEnvironment(["setenv", "CODEX_APP_SERVER_FORCE_CLI", "0"])
            _ = try launchEnvironment(["setenv", "CODEX_APP_SERVER_WS_URL", "ws://127.0.0.1:1"])
            changedEnvironment = true
            for coordinator in coordinators {
                _ = try await coordinator.refreshThreadState()
                guard !coordinator.threads.contains(where: { $0.runState == .running }) else { throw CodexAccountError.activeTasks }
            }
            applications.forEach { _ = $0.terminate() }
            for _ in 0..<200 {
                let remaining = descendants.filter { Darwin.kill($0, 0) == 0 }
                if applications.allSatisfy(\.isTerminated), remaining.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard applications.allSatisfy(\.isTerminated), descendants.allSatisfy({ Darwin.kill($0, 0) != 0 }) else { throw ChatHandoffError.unsafeOwner }
            try SharedChatProjectAliases.prepare(configuration: configuration, catalog: catalog)
            if updatingServer { try await stopServer() }
            try JSONEncoder().encode(configuration).write(to: configurationURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
            try? fm.removeItem(at: root.appendingPathComponent("ready.json"))
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--shared-chat-server", configurationURL.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            for _ in 0..<200 {
                if fm.fileExists(atPath: root.appendingPathComponent("ready.json").path) { break }
                guard process.isRunning else { throw ChatHandoffError.disconnected }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard fm.fileExists(atPath: root.appendingPathComponent("ready.json").path) else { process.terminate(); throw ChatHandoffError.disconnected }
            try Data(String(process.processIdentifier).utf8).write(to: root.appendingPathComponent("pid"), options: .atomic)
            try Data().write(to: root.appendingPathComponent("enabled"), options: .atomic)
            let connection = environment(windowID: "main")["CODEX_APP_SERVER_WS_URL"]!
            _ = try launchEnvironment(["setenv", "CODEX_APP_SERVER_WS_URL", connection])
            CodexConfiguration.selectFreshDevToolsPortForLaunch()
            let mainLaunch = NSWorkspace.OpenConfiguration()
            mainLaunch.createsNewApplicationInstance = true
            mainLaunch.arguments = CodexConfiguration.launchArguments
            mainLaunch.environment = environment(windowID: "main")
            _ = try await NSWorkspace.shared.openApplication(at: CodexConfiguration.codexApplicationURL, configuration: mainLaunch)
            for profile in profiles {
                let launch = NSWorkspace.OpenConfiguration()
                launch.createsNewApplicationInstance = true
                launch.arguments = profile.arguments + CodexConfiguration.debugArguments(port: CodexConfiguration.randomDevToolsPort())
                launch.environment = profile.environment
                _ = try await NSWorkspace.shared.openApplication(at: CodexConfiguration.codexApplicationURL, configuration: launch)
            }
            main.accounts.setStatusMessage("Shared chats enabled. Each window uses its own account when starting a turn.")
            return .enabled
        } catch {
            if changedEnvironment && updatingServer && isRunning,
               let connection = environment(windowID: "main")["CODEX_APP_SERVER_WS_URL"] {
                _ = try? launchEnvironment(["setenv", "CODEX_APP_SERVER_WS_URL", connection])
            } else if changedEnvironment && !isEnabled {
                let previous = (try? String(contentsOf: root.appendingPathComponent("previous-ws-url"), encoding: .utf8)) ?? ""
                _ = try? launchEnvironment(previous.isEmpty ? ["unsetenv", "CODEX_APP_SERVER_WS_URL"] : ["setenv", "CODEX_APP_SERVER_WS_URL", previous])
                let forceCLI = (try? String(contentsOf: root.appendingPathComponent("previous-force-cli"), encoding: .utf8)) ?? ""
                _ = try? launchEnvironment(forceCLI.isEmpty ? ["unsetenv", "CODEX_APP_SERVER_FORCE_CLI"] : ["setenv", "CODEX_APP_SERVER_FORCE_CLI", forceCLI])
            }
            main.accounts.setStatusMessage("Shared chats could not be enabled. " + error.localizedDescription)
            if case CodexAccountError.activeTasks = error { return .waitingForIdle }
            return .failed
        }
    }

    @MainActor
    static func disable(main: AppCoordinator, windows: AccountWindowDashboards?) async {
        let coordinators = [main] + (windows?.entries.values.map(\.coordinator) ?? [])
        guard coordinators.allSatisfy({ !$0.isPerformingAction }) else { return }
        for coordinator in coordinators { coordinator.isPerformingAction = true }
        defer { for coordinator in coordinators { coordinator.isPerformingAction = false } }
        do {
            if !isRunning && historyOwnerIsRunning { throw ChatHandoffError.unsafeOwner }
            for coordinator in coordinators {
                await coordinator.cancelSynchronization()
                _ = try await coordinator.refreshThreadState()
                guard !coordinator.threads.contains(where: { $0.runState == .running }) else { throw CodexAccountError.activeTasks }
            }
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier)
            let secondary = applications.compactMap { app -> AccountWindowProfile? in
                guard let args = CodexConfiguration.processArguments(for: app.processIdentifier) else { return nil }
                return main.accounts.savedAccounts.map { AccountWindowProfile(accountID: $0.id) }.first { $0.matches(processArguments: args) }
            }
            applications.forEach { _ = $0.terminate() }
            for _ in 0..<200 where !applications.allSatisfy(\.isTerminated) { try await Task.sleep(for: .milliseconds(50)) }
            guard applications.allSatisfy(\.isTerminated) else { throw ChatHandoffError.busy }
            try await stopServer()
            let previous = (try? String(contentsOf: root.appendingPathComponent("previous-ws-url"), encoding: .utf8)) ?? ""
            _ = try launchEnvironment(previous.isEmpty ? ["unsetenv", "CODEX_APP_SERVER_WS_URL"] : ["setenv", "CODEX_APP_SERVER_WS_URL", previous])
            let forceCLI = (try? String(contentsOf: root.appendingPathComponent("previous-force-cli"), encoding: .utf8)) ?? ""
            _ = try launchEnvironment(forceCLI.isEmpty ? ["unsetenv", "CODEX_APP_SERVER_FORCE_CLI"] : ["setenv", "CODEX_APP_SERVER_FORCE_CLI", forceCLI])
            try FileManager.default.removeItem(at: root.appendingPathComponent("enabled"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent("ready.json"))
            CodexConfiguration.selectFreshDevToolsPortForLaunch()
            let launch = NSWorkspace.OpenConfiguration()
            launch.createsNewApplicationInstance = true
            launch.arguments = CodexConfiguration.launchArguments
            _ = try await NSWorkspace.shared.openApplication(at: CodexConfiguration.codexApplicationURL, configuration: launch)
            for profile in secondary {
                let launch = NSWorkspace.OpenConfiguration()
                launch.createsNewApplicationInstance = true
                launch.arguments = profile.arguments + CodexConfiguration.debugArguments(port: CodexConfiguration.randomDevToolsPort())
                launch.environment = profile.environment
                _ = try await NSWorkspace.shared.openApplication(at: CodexConfiguration.codexApplicationURL, configuration: launch)
            }
            main.accounts.setStatusMessage("Shared chats disabled. All shared chat history remains in the main window.")
        } catch { main.accounts.setStatusMessage("Shared chats could not be disabled. " + error.localizedDescription) }
    }

    private static func stopServer() async throws {
        if isRunning, let text = try? String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8),
           let pid = pid_t(text) {
            for _ in 0..<100 where Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGTERM)
                try await Task.sleep(for: .milliseconds(100))
            }
            guard Darwin.kill(pid, 0) != 0 else { throw ChatHandoffError.busy }
        }
        guard !historyOwnerIsRunning else { throw ChatHandoffError.unsafeOwner }
    }

    private static func launchEnvironment(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        // getenv uses a nonzero status when the variable is absent.
        guard process.terminationStatus == 0 || arguments.first == "getenv" else { throw ChatHandoffError.disconnected }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func processDescendants(of roots: Set<pid_t>) throws -> Set<pid_t> {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ChatHandoffError.unsafeOwner }
        let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { row -> (pid_t, pid_t)? in
            let columns = row.split(whereSeparator: \.isWhitespace)
            guard columns.count == 2, let pid = pid_t(columns[0]), let parent = pid_t(columns[1]) else { return nil }
            return (pid, parent)
        }
        var result = roots
        while true {
            let expanded = result.union(pairs.filter { result.contains($0.1) }.map(\.0))
            if expanded == result { return result.subtracting(roots) }
            result = expanded
        }
    }
}
