import AppKit

/// One coordinator and renderer connection per running account profile. Keeping
/// coordinators independent also scopes reviews, account actions, and file watches.
@MainActor
final class AccountWindowDashboards {
    struct WindowID: Hashable {
        let accountID: UUID
        let managed: Bool
    }
    struct Entry {
        let context: AccountWindowRuntimeContext
        let coordinator: AppCoordinator
    }
    private(set) var entries: [WindowID: Entry] = [:]
    private var projectSync: SharedProjectSynchronizer?
    private var projectSyncError: String?
    private var managedPresentation: SharedProjectSynchronizer?
    private var monitorTask: Task<Void, Never>?

    func start() {
        guard monitorTask == nil else { return }
        do {
            projectSync = try SharedProjectSynchronizer()
            managedPresentation = try SharedProjectSynchronizer(file: ManagedChatWorkspace().root.appendingPathComponent("presentation.json"))
        }
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
        if let sync = managedPresentation { Task { await sync.disconnect() } }
        managedPresentation = nil
    }

    private func reconcile() async {
        let workspace = ManagedChatWorkspace()
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: CodexConfiguration.bundleIdentifier)
        let arguments = applications.compactMap { CodexConfiguration.processArguments(for: $0.processIdentifier) }
        var running: [WindowID: (profile: AccountWindowProfile, arguments: String)] = [:]
        for (directory, managed) in [
            (CodexConfiguration.dashboardSupportDirectory().appendingPathComponent("account-windows"), false),
            (workspace.windows, true),
        ] {
            let profiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for path in profiles {
                guard let id = UUID(uuidString: path.lastPathComponent) else { continue }
                let profile = AccountWindowProfile(accountID: id, profilesDirectory: directory)
                if let argument = arguments.first(where: { profile.matches(processArguments: $0) }) {
                    running[WindowID(accountID: id, managed: managed)] = (profile, argument)
                }
            }
        }
        for id in Array(entries.keys) where running[id] == nil {
            // A scoped restart briefly has no process; keep its coordinator and
            // operation alive until the replacement process has been launched.
            guard let entry = entries[id], !entry.coordinator.isPerformingAction else { continue }
            entries.removeValue(forKey: id)
            entry.coordinator.stopMonitoring()
            await entry.coordinator.disconnectRuntime()
        }
        for (id, window) in running {
            guard let entry = entries[id], !entry.coordinator.isPerformingAction,
                  !entry.context.matches(arguments: window.arguments) else { continue }
            entries.removeValue(forKey: id)
            entry.coordinator.stopMonitoring()
            await entry.coordinator.disconnectRuntime()
        }
        for (id, window) in running where entries[id] == nil {
            guard !Task.isCancelled else { return }
            let profile = window.profile
            guard !Task.isCancelled else { return }
            do {
                let context = AccountWindowRuntimeContext(profile: profile, arguments: window.arguments, managedWorkspace: id.managed ? workspace : nil)
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
        for (id, entry) in entries where !id.managed && !entry.coordinator.isPerformingAction {
            let port = entry.context.port
            let replicaID = id.accountID.uuidString
            let stateHome = entry.context.profile.codexHome
            endpoints.append((replicaID, stateHome, { port.port }))
        }
        if endpoints.count > 1 { await projectSync?.synchronize(endpoints: endpoints) }
        let managed = entries.filter { $0.key.managed && !$0.value.coordinator.isPerformingAction }
            .sorted { $0.key.accountID.uuidString < $1.key.accountID.uuidString }
        if !managed.isEmpty {
            let shared = managed.enumerated().map { index, window in
                let port = window.value.context.port
                return (id: index == 0 ? "main" : "shared:" + window.key.accountID.uuidString,
                        home: workspace.server.appendingPathComponent("owner"), port: { @Sendable in port.port })
            }
            await managedPresentation?.synchronizeSharedPresentation(endpoints: shared)
        }
        for entry in entries.values {
            writeStatus(profile: entry.context.profile,
                state: entry.coordinator.statusPresentation.title,
                detail: entry.coordinator.connectionError ?? entry.coordinator.connectionNotice ?? projectSync?.lastError ?? projectSyncError)
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
