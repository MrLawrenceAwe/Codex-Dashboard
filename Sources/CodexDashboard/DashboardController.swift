import AppKit
import Foundation

enum DashboardState: Equatable {
    case checking
    case hostClosed
    case hostRunning
    case connected
    case enabled
    case needsAttention(message: String, hostConnected: Bool, dashboardEnabled: Bool)

    var hostIsConnected: Bool {
        switch self {
        case .connected, .enabled:
            return true
        case .needsAttention(_, let hostConnected, _):
            return hostConnected
        default:
            return false
        }
    }

    var dashboardIsEnabled: Bool {
        switch self {
        case .enabled:
            return true
        case .needsAttention(_, _, let dashboardEnabled):
            return dashboardEnabled
        default:
            return false
        }
    }

    var errorMessage: String? {
        guard case .needsAttention(let message, _, _) = self else { return nil }
        return message
    }
}

@MainActor
final class DashboardController: ObservableObject {
    @Published private(set) var state: DashboardState = .checking
    @Published private(set) var isBusy = false
    @Published private(set) var dataWarning: String?
    @Published private(set) var tasks: [DashboardTask] = []
    @Published private(set) var totalTaskCount = 0

    private let devTools = DevToolsClient()
    private let taskRepository = CodexTaskRepository()
    private var adapter: DashboardAdapter?
    private var shouldMaintainDashboard = true
    private var monitor: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var enabledTargetIDs: Set<String> = []
    private var lastDeliveredPayload: DashboardPayload?

    var statusTitle: String {
        switch state {
        case .checking: "Checking Codex…"
        case .hostClosed: "Codex is closed"
        case .hostRunning: "Codex is running normally"
        case .connected: "Codex is connected"
        case .enabled: "Dashboard is live"
        case .needsAttention: "Dashboard needs attention"
        }
    }

    var statusDetail: String {
        switch state {
        case .checking:
            "Looking for the local Codex host application."
        case .hostClosed:
            "Dashboard can launch it with the local bridge enabled."
        case .hostRunning:
            "Restart it through Dashboard once to add the task view."
        case .connected:
            "The local renderer is ready for the task dashboard."
        case .enabled:
            activitySummary
        case .needsAttention:
            "Review the message below and try again."
        }
    }

    init() {
        do {
            adapter = try DashboardAdapter.load()
        } catch {
            state = .needsAttention(
                message: error.localizedDescription,
                hostConnected: false,
                dashboardEnabled: false
            )
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit {
        monitor?.cancel()
        refreshTask?.cancel()
    }

    func refresh() async {
        guard !isBusy else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        do {
            let snapshot = try await taskRepository.loadSnapshot()
            guard !Task.isCancelled else { return }
            tasks = snapshot.tasks
            totalTaskCount = snapshot.totalTaskCount
            dataWarning = snapshot.warning
        } catch {
            dataWarning = "Task data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)"
        }

        guard !Task.isCancelled, !isBusy else { return }
        let hostIsRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppConfiguration.hostBundleIdentifier
        ).isEmpty
        let targets = await devTools.mainRendererTargets()
        guard !Task.isCancelled, !isBusy else { return }

        if shouldMaintainDashboard, !targets.isEmpty {
            do {
                try await synchronizeDashboard(with: targets)
            } catch {
                guard !Task.isCancelled, shouldMaintainDashboard else { return }
                setFailure(error, hostConnected: true)
            }
            return
        }
        if state.errorMessage != nil { return }
        if !targets.isEmpty {
            state = .connected
        } else {
            state = hostIsRunning ? .hostRunning : .hostClosed
        }
    }

    func restartCodexAndEnableDashboard() async {
        guard !isBusy else { return }
        isBusy = true
        shouldMaintainDashboard = false
        enabledTargetIDs = []
        lastDeliveredPayload = nil
        state = .checking
        defer { isBusy = false }
        await cancelRefresh()

        do {
            let executableURL = AppConfiguration.hostExecutableURL
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw DashboardError.missingHostApplication
            }
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: AppConfiguration.hostBundleIdentifier
            )
            applications.forEach { $0.terminate() }

            let quitDeadline = ContinuousClock.now + .seconds(12)
            while !NSRunningApplication.runningApplications(
                withBundleIdentifier: AppConfiguration.hostBundleIdentifier
            ).isEmpty {
                guard ContinuousClock.now < quitDeadline else {
                    throw DashboardError.hostQuitTimedOut
                }
                try await Task.sleep(for: .milliseconds(250))
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                "--remote-debugging-address=\(AppConfiguration.devToolsHost)",
                "--remote-debugging-port=\(AppConfiguration.devToolsPort)",
                "--remote-allow-origins=http://localhost",
            ]
            try process.run()

            let rendererDeadline = ContinuousClock.now + .seconds(18)
            var targets: [DevToolsTarget] = []
            while targets.isEmpty {
                targets = await devTools.mainRendererTargets()
                if !targets.isEmpty { break }
                guard ContinuousClock.now < rendererDeadline else {
                    throw DashboardError.rendererTimedOut
                }
                try await Task.sleep(for: .milliseconds(350))
            }

            let snapshot = try await taskRepository.loadSnapshot()
            tasks = snapshot.tasks
            totalTaskCount = snapshot.totalTaskCount
            dataWarning = snapshot.warning
            shouldMaintainDashboard = true
            try await synchronizeDashboard(with: targets, forceMount: true)
        } catch {
            setFailure(error, hostConnected: false)
        }
    }

    func disableDashboard() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        shouldMaintainDashboard = false
        await cancelRefresh()

        let targets = await devTools.mainRendererTargets()
        guard !targets.isEmpty else {
            enabledTargetIDs = []
            lastDeliveredPayload = nil
            state = .hostClosed
            return
        }

        var disablementConfirmed = false
        do {
            for target in targets {
                let disabled = try await devTools.evaluateBoolean(
                    "(() => { window.__codexDashboard?.destroy?.(); return typeof window.__codexDashboard === 'undefined'; })()",
                    in: target
                )
                guard disabled else {
                    throw DashboardError.disableFailed("The renderer still reports an active dashboard.")
                }
            }
            disablementConfirmed = true
            enabledTargetIDs = []
            lastDeliveredPayload = nil
            state = .connected
        } catch {
            state = .needsAttention(
                message: error.localizedDescription,
                hostConnected: true,
                dashboardEnabled: !disablementConfirmed
            )
        }
    }

    func openDashboard() async {
        for target in await devTools.mainRendererTargets() {
            _ = try? await devTools.evaluateBoolean(
                "(() => { window.__codexDashboard?.open?.(); return true; })()",
                in: target
            )
        }
    }

    private var activitySummary: String {
        let runningCount = tasks.count { $0.status == .running }
        let recentCount = tasks.count { $0.status == .recent }
        return "\(runningCount) running · \(recentCount) recently active"
    }

    private func synchronizeDashboard(
        with targets: [DevToolsTarget],
        forceMount: Bool = false
    ) async throws {
        guard let adapter else { throw DashboardError.missingResources }
        let targetIDs = Set(targets.map(\.id))
        var mountedDashboard = false

        for target in targets {
            try Task.checkCancellation()
            guard shouldMaintainDashboard else { return }
            let canCheckExistingDashboard = !forceMount && enabledTargetIDs.contains(target.id)
            let isHealthy: Bool
            if canCheckExistingDashboard {
                isHealthy = (try? await devTools.evaluateBoolean(
                    adapter.healthCheckExpression,
                    in: target
                )) == true
            } else {
                isHealthy = false
            }
            guard !Task.isCancelled, shouldMaintainDashboard else { return }
            if !isHealthy {
                guard try await devTools.evaluateBoolean(
                    adapter.expression,
                    in: target,
                    bypassContentSecurityPolicy: true
                ) else {
                    throw DashboardError.enableFailed(
                        "The adapter did not mount in the Codex renderer."
                    )
                }
                mountedDashboard = true
            }
        }

        let payload = DashboardPayload(tasks: tasks, totalTaskCount: totalTaskCount)
        if mountedDashboard || payload != lastDeliveredPayload || targetIDs != enabledTargetIDs {
            try await deliver(payload, to: targets)
            lastDeliveredPayload = payload
        }
        enabledTargetIDs = targetIDs
        state = .enabled
    }

    private func deliver(_ payload: DashboardPayload, to targets: [DevToolsTarget]) async throws {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DashboardError.enableFailed("Task data could not be encoded for the renderer.")
        }
        let expression = """
        (() => {
          const dashboard = window.__codexDashboard;
          if (typeof dashboard?.update !== 'function') return false;
          dashboard.update(\(json));
          return true;
        })()
        """
        for target in targets {
            guard try await devTools.evaluateBoolean(expression, in: target) else {
                throw DashboardError.enableFailed(
                    "The dashboard was unavailable while task data was being delivered."
                )
            }
        }
    }

    private func cancelRefresh() async {
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        await task?.value
    }

    private func setFailure(_ error: Error, hostConnected: Bool) {
        state = .needsAttention(
            message: error.localizedDescription,
            hostConnected: hostConnected,
            dashboardEnabled: false
        )
    }
}
