import AppKit

/// One coordinator and renderer connection per running account profile. Keeping
/// coordinators independent also scopes reviews, account actions, and file watches.
@MainActor
final class AccountWindowDashboards {
    struct Entry {
        let context: AccountWindowRuntimeContext
        let coordinator: AppCoordinator
    }
    private(set) var entries: [UUID: Entry] = [:]
    private var projectSync: SharedProjectSynchronizer?
    private var projectSyncError: String?
    private weak var mainCoordinator: AppCoordinator?
    private var activationGate = ChatHandoffActivationGate()
    private var monitorTask: Task<Void, Never>?

    func start(main: AppCoordinator) {
        mainCoordinator = main
        guard monitorTask == nil else { return }
        do { projectSync = try SharedProjectSynchronizer() }
        catch { projectSyncError = error.localizedDescription }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        for entry in entries.values {
            entry.coordinator.stopMonitoring()
            Task { await entry.coordinator.disconnectRuntime() }
        }
        entries.removeAll()
        if let sync = projectSync { Task { await sync.disconnect() } }
        projectSync = nil
    }

    private func reconcile() async {
        let profiles = CodexConfiguration.dashboardSupportDirectory().appendingPathComponent("account-windows")
        let directories = (try? FileManager.default.contentsOfDirectory(at: profiles,
            includingPropertiesForKeys: nil)) ?? []
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier)
        var running: [UUID: String] = [:]
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let profile = AccountWindowProfile(accountID: id)
            if let arguments = applications.compactMap({ CodexConfiguration.processArguments(for: $0.processIdentifier) })
                .first(where: { profile.matches(processArguments: $0) }) { running[id] = arguments }
        }
        for id in Array(entries.keys) where running[id] == nil {
            // A scoped restart briefly has no process; keep its coordinator and
            // operation alive until the replacement process has been launched.
            guard let entry = entries[id], !entry.coordinator.isPerformingAction else { continue }
            entries.removeValue(forKey: id)
            entry.coordinator.stopMonitoring()
            await entry.coordinator.disconnectRuntime()
        }
        for (id, arguments) in running {
            guard let entry = entries[id], !entry.coordinator.isPerformingAction,
                  !entry.context.matches(arguments: arguments, sharedChats: ChatHandoffService.isEnabled) else { continue }
            entries.removeValue(forKey: id)
            entry.coordinator.stopMonitoring()
            await entry.coordinator.disconnectRuntime()
        }
        for (id, arguments) in running where entries[id] == nil {
            guard !Task.isCancelled else { return }
            let profile = AccountWindowProfile(accountID: id)
            guard !Task.isCancelled else { return }
            do {
                let context = AccountWindowRuntimeContext(profile: profile, arguments: arguments)
                let coordinator = try context.makeCoordinator()
                entries[id] = Entry(context: context, coordinator: coordinator)
                coordinator.startMonitoring()
            } catch {
                writeStatus(profile: profile, state: "unavailable", detail: error.localizedDescription)
            }
        }
        var endpoints: [(id: String, home: URL, port: @Sendable () -> Int)] = [
            ("main", CodexConfiguration.codexDirectory, { CodexConfiguration.devToolsPort })
        ]
        for (id, entry) in entries where !entry.coordinator.isPerformingAction {
            let port = entry.context.port
            let replicaID = (entry.context.sharedChats ? "shared:" : "") + id.uuidString
            endpoints.append((replicaID, entry.context.profile.codexHome, { port.port }))
        }
        if !entries.isEmpty { await projectSync?.synchronize(endpoints: endpoints) }
        for entry in entries.values {
            writeStatus(profile: entry.context.profile,
                state: entry.coordinator.statusPresentation.title,
                detail: entry.coordinator.connectionError ?? entry.coordinator.connectionNotice ?? projectSync?.lastError ?? projectSyncError)
        }
        _ = await activateSharedChatsWhenIdle(expectedAccounts: Set(running.keys))
    }

    private func activateSharedChatsWhenIdle(expectedAccounts: Set<UUID>) async -> Bool {
        guard ChatHandoffService.activationRequested, let main = mainCoordinator else {
            activationGate.reset()
            return false
        }
        guard expectedAccounts.allSatisfy({ entries[$0] != nil }) else {
            activationGate.reset()
            return false
        }
        let coordinators = [main] + entries.values.map(\.coordinator)
        guard coordinators.allSatisfy({ !$0.isPerformingAction }) else {
            activationGate.reset()
            return false
        }
        do {
            for coordinator in coordinators { _ = try await coordinator.refreshThreadState() }
            guard coordinators.allSatisfy({ !$0.threads.contains(where: { $0.runState == .running }) })
                    || ChatHandoffService.stoppedWriterNeedsRecovery else {
                activationGate.reset()
                main.accounts.setStatusMessage("Shared Chats is waiting for running turns to finish. Your history remains in the main window.")
                return false
            }
            guard activationGate.observeIdle() else { return false }
            let outcome = await ChatHandoffService.enable(main: main, windows: self)
            if case .waitingForIdle = outcome {
                activationGate.reset()
                return false
            }
            try ChatHandoffService.consumeActivationRequest()
            activationGate.reset()
            return true
        } catch {
            activationGate.reset()
            main.accounts.setStatusMessage("Shared Chats is waiting because active chats could not be checked. " + error.localizedDescription)
            return false
        }
    }

    private func writeStatus(profile: AccountWindowProfile, state: String, detail: String?) {
        let payload: [String: Any] = ["state": state, "detail": detail ?? "", "accountID": profile.accountID.uuidString]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        let file = profile.dashboardDirectory.appendingPathComponent("connection.json")
        guard (try? Data(contentsOf: file)) != data else { return }
        do {
            try FileManager.default.createDirectory(at: profile.dashboardDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Diagnostics must not interrupt an account window. */ }
    }
}
