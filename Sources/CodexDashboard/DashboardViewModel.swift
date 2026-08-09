import Foundation

enum DashboardSessionState: Equatable {
    case checking
    case appClosed
    case appRunning
    case bridgeConnected
    case dashboardMounted
    case needsAttention(message: String, bridgeConnected: Bool, dashboardMounted: Bool)

    var bridgeIsConnected: Bool {
        switch self {
        case .bridgeConnected, .dashboardMounted:
            return true
        case .needsAttention(_, let bridgeConnected, _):
            return bridgeConnected
        default:
            return false
        }
    }

    var dashboardIsMounted: Bool {
        switch self {
        case .dashboardMounted:
            return true
        case .needsAttention(_, _, let dashboardMounted):
            return dashboardMounted
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
final class DashboardViewModel: ObservableObject {
    @Published private(set) var sessionState: DashboardSessionState = .checking
    @Published private(set) var isPerformingAction = false
    @Published private(set) var dataWarning: String?
    @Published private(set) var threads: [DashboardThread] = []
    @Published private(set) var totalThreadCount = 0

    private let threadRepository = CodexThreadRepository()
    private let gitStatusLoader = WorkspaceGitStatusLoader()
    private var hostSession: CodexHostSession?
    private var threadRefreshLoopTask: Task<Void, Never>?
    private var gitRefreshLoopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var gitStatuses: [String: WorkspaceGitStatus] = [:]

    var statusTitle: String {
        switch sessionState {
        case .checking: "Checking Codex…"
        case .appClosed: "Codex is closed"
        case .appRunning: "Codex is running without the dashboard bridge"
        case .bridgeConnected: "Dashboard bridge is connected"
        case .dashboardMounted: "Dashboard is live"
        case .needsAttention: "Dashboard needs attention"
        }
    }

    var statusDetail: String {
        switch sessionState {
        case .checking:
            "Looking for the local Codex app."
        case .appClosed:
            "The dashboard can relaunch it with local debugging enabled."
        case .appRunning:
            "Restart it through this controller once to enable the thread dashboard."
        case .bridgeConnected:
            "The local renderer is ready for the thread dashboard."
        case .dashboardMounted:
            activitySummary
        case .needsAttention:
            "Review the message below and try again."
        }
    }

    init() {
        do {
            hostSession = try CodexHostSession()
        } catch {
            setFailure(error, bridgeConnected: false)
        }
        startRefreshLoops()
    }

    deinit {
        threadRefreshLoopTask?.cancel()
        gitRefreshLoopTask?.cancel()
        refreshTask?.cancel()
    }

    func refresh() async {
        guard !isPerformingAction else { return }
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

    func restartAndEnableDashboard() async {
        guard !isPerformingAction, let hostSession else { return }
        isPerformingAction = true
        hostSession.prepareForRestart()
        sessionState = .checking
        defer { isPerformingAction = false }
        await cancelRefresh()
        var bridgeConnected = false

        do {
            let targets = try await hostSession.restartApplication()
            bridgeConnected = true
            try await refreshThreadSnapshot()
            try await hostSession.mountDashboard(
                with: DashboardPayload(threads: threads),
                on: targets,
                force: true
            )
            sessionState = .dashboardMounted
        } catch {
            setFailure(error, bridgeConnected: bridgeConnected)
        }
    }

    func disableDashboard() async {
        guard !isPerformingAction, let hostSession else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        await cancelRefresh()

        do {
            switch try await hostSession.disableDashboard() {
            case .applicationClosed:
                sessionState = .appClosed
            case .bridgeConnected:
                sessionState = .bridgeConnected
            }
        } catch {
            sessionState = .needsAttention(
                message: error.localizedDescription,
                bridgeConnected: true,
                dashboardMounted: true
            )
        }
    }

    func openDashboard() async {
        await hostSession?.openDashboard()
    }

    private func startRefreshLoops() {
        threadRefreshLoopTask = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                await self?.refresh()
                deadline += .seconds(2)
                if deadline < clock.now { deadline = clock.now }
                try? await clock.sleep(until: deadline)
            }
        }
        gitRefreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshGitStatuses()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func performRefresh() async {
        do {
            try await refreshThreadSnapshot()
        } catch {
            dataWarning = "Thread data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)"
        }

        guard
            !Task.isCancelled,
            !isPerformingAction,
            let hostSession
        else { return }

        let appIsRunning = hostSession.applicationIsRunning
        let targets = await hostSession.mainRendererTargets()
        guard !Task.isCancelled, !isPerformingAction else { return }

        if hostSession.keepsDashboardMounted, !targets.isEmpty {
            do {
                try await hostSession.mountDashboard(
                    with: DashboardPayload(threads: threads),
                    on: targets
                )
                sessionState = .dashboardMounted
            } catch {
                guard !Task.isCancelled, hostSession.keepsDashboardMounted else { return }
                setFailure(error, bridgeConnected: true)
            }
            return
        }
        if sessionState.errorMessage != nil { return }
        sessionState = !targets.isEmpty
            ? .bridgeConnected
            : (appIsRunning ? .appRunning : .appClosed)
    }

    private func refreshThreadSnapshot() async throws {
        let snapshot = try await threadRepository.loadSnapshot(
            gitStatuses: gitStatuses,
            activeApplicationLaunchDate: hostSession?.applicationLaunchDate
        )
        guard !Task.isCancelled else { return }
        threads = snapshot.threads
        totalThreadCount = snapshot.totalThreadCount
        dataWarning = nil
    }

    private func refreshGitStatuses() async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await refresh() }
        let workspacePaths = Set(threads.map(\.workspacePath))
        guard !workspacePaths.isEmpty, !Task.isCancelled else { return }
        gitStatuses = await gitStatusLoader.load(at: workspacePaths)
        guard !Task.isCancelled else { return }
        await refresh()
    }

    private var activitySummary: String {
        let runningCount = threads.count { $0.activity == .running }
        return "\(runningCount) running · \(totalThreadCount) total threads"
    }

    private func cancelRefresh() async {
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        await task?.value
    }

    private func setFailure(_ error: Error, bridgeConnected: Bool) {
        sessionState = .needsAttention(
            message: error.localizedDescription,
            bridgeConnected: bridgeConnected,
            dashboardMounted: false
        )
    }
}
