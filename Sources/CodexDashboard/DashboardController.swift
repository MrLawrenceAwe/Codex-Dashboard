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
    private var enableGeneration = 0
    private var activeEnableAttempts = 0
    private var monitor: Task<Void, Never>?

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

    deinit { monitor?.cancel() }

    func refresh() async {
        do {
            let snapshot = try await taskRepository.loadSnapshot()
            tasks = snapshot.tasks
            totalTaskCount = snapshot.totalTaskCount
            dataWarning = snapshot.warning
        } catch {
            dataWarning = "Task data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)"
        }

        guard !isBusy else { return }
        let hostIsRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppConfiguration.hostBundleIdentifier
        ).isEmpty
        let targets = await devTools.mainRendererTargets()
        guard !isBusy else { return }

        if shouldMaintainDashboard, !targets.isEmpty {
            await enableDashboard(showsProgress: false)
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
        enableGeneration &+= 1
        shouldMaintainDashboard = false
        state = .checking
        defer { isBusy = false }

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
            while await devTools.mainRendererTargets().isEmpty {
                guard ContinuousClock.now < rendererDeadline else {
                    throw DashboardError.rendererTimedOut
                }
                try await Task.sleep(for: .milliseconds(350))
            }

            enableGeneration &+= 1
            shouldMaintainDashboard = true
            await enableDashboard(showsProgress: false)
            await refresh()
        } catch {
            setFailure(error, hostConnected: false)
        }
    }

    func enableDashboard(showsProgress: Bool = true) async {
        guard !isBusy || !showsProgress else { return }
        guard shouldMaintainDashboard else { return }
        let generation = enableGeneration
        activeEnableAttempts += 1
        defer { activeEnableAttempts -= 1 }
        if showsProgress { isBusy = true }
        defer { if showsProgress { isBusy = false } }

        do {
            guard let adapter else { throw DashboardError.missingResources }
            let targets = await devTools.mainRendererTargets()
            guard generation == enableGeneration, shouldMaintainDashboard else { return }
            guard !targets.isEmpty else { throw DashboardError.rendererTimedOut }
            var enabledRendererCount = 0
            for target in targets {
                guard generation == enableGeneration, shouldMaintainDashboard else { return }
                do {
                    if try await devTools.evaluateBoolean(
                        adapter.expression,
                        in: target,
                        bypassContentSecurityPolicy: true
                    ) {
                        enabledRendererCount += 1
                    }
                    try await restoreContentSecurityPolicy(in: target)
                } catch {
                    try? await restoreContentSecurityPolicy(in: target)
                    throw error
                }
            }
            guard generation == enableGeneration, shouldMaintainDashboard else { return }
            guard enabledRendererCount > 0 else {
                throw DashboardError.enableFailed("The adapter did not mount in the Codex renderer.")
            }
            try await deliverTasks(to: targets)
            guard generation == enableGeneration, shouldMaintainDashboard else { return }
            state = .enabled
        } catch {
            guard generation == enableGeneration, shouldMaintainDashboard else { return }
            setFailure(error, hostConnected: true)
        }
    }

    func disableDashboard() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        enableGeneration &+= 1
        shouldMaintainDashboard = false

        while activeEnableAttempts > 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let targets = await devTools.mainRendererTargets()
        guard !targets.isEmpty else {
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
            for target in targets {
                try await restoreContentSecurityPolicy(in: target)
            }
            state = .connected
        } catch {
            for target in targets {
                try? await restoreContentSecurityPolicy(in: target)
            }
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

    private func restoreContentSecurityPolicy(in target: DevToolsTarget) async throws {
        try await devTools.setContentSecurityPolicyBypass(false, in: target)
    }

    private func deliverTasks(to targets: [DevToolsTarget]) async throws {
        let payload = DashboardPayload(tasks: tasks, totalTaskCount: totalTaskCount)
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

    private func setFailure(_ error: Error, hostConnected: Bool) {
        state = .needsAttention(
            message: error.localizedDescription,
            hostConnected: hostConnected,
            dashboardEnabled: false
        )
    }
}
