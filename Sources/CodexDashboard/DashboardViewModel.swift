import Foundation

enum DashboardConnectionState: Equatable {
    case checking
    case appClosed
    case appRunning
    case rendererAvailable
    case dashboardMounted

    var rendererIsAvailable: Bool {
        self == .rendererAvailable || self == .dashboardMounted
    }

    var dashboardIsMounted: Bool {
        self == .dashboardMounted
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var connectionState: DashboardConnectionState = .checking
    @Published private(set) var sessionError: String?
    @Published private(set) var isPerformingAction = false
    @Published private(set) var dataWarning: String?
    @Published private(set) var threads: [DashboardThread] = []
    @Published private(set) var availableThreadCount = 0

    private let threadRepository: any ThreadSnapshotLoading
    private let gitStatusLoader: any GitWorkingTreeStatusLoading
    private let unreadStateLoader: any UnreadStateLoading
    private var dashboardHost: (any DashboardHost)?
    private var threadRefreshLoopTask: Task<Void, Never>?
    private var gitRefreshLoopTask: Task<Void, Never>?
    private var unreadRefreshLoopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var gitWorkingTreeStatuses: [String: GitWorkingTreeStatus] = [:]
    private var unreadThreadIDs: Set<String> = []

    var statusPresentation: (title: String, detail: String) {
        if sessionError != nil {
            return ("Dashboard needs attention", "Review the message below and try again.")
        }
        return switch connectionState {
        case .checking:
            ("Checking Codex…", "Looking for the local Codex app.")
        case .appClosed:
            ("Codex is closed", "The dashboard can relaunch it with local debugging enabled.")
        case .appRunning:
            (
                "Codex is running without the dashboard connection",
                "Restart it through this controller once to enable the thread dashboard."
            )
        case .rendererAvailable:
            ("Dashboard connection is available", "The local renderer is ready for the thread dashboard.")
        case .dashboardMounted:
            ("Dashboard is live", activitySummary)
        }
    }

    init(
        threadRepository: any ThreadSnapshotLoading = CodexThreadRepository(),
        gitStatusLoader: any GitWorkingTreeStatusLoading = GitWorkingTreeStatusLoader(),
        unreadStateLoader: any UnreadStateLoading = CodexUnreadStateReader(),
        dashboardHostFactory: () throws -> any DashboardHost = { try CodexDashboardHost() }
    ) {
        self.threadRepository = threadRepository
        self.gitStatusLoader = gitStatusLoader
        self.unreadStateLoader = unreadStateLoader
        do {
            dashboardHost = try dashboardHostFactory()
        } catch {
            setFailure(error, lastKnownState: .appClosed)
        }
    }

    deinit {
        threadRefreshLoopTask?.cancel()
        gitRefreshLoopTask?.cancel()
        unreadRefreshLoopTask?.cancel()
        refreshTask?.cancel()
    }

    func startRefreshing() {
        guard
            threadRefreshLoopTask == nil,
            gitRefreshLoopTask == nil,
            unreadRefreshLoopTask == nil
        else { return }
        startRefreshLoops()
    }

    func stopRefreshing() {
        threadRefreshLoopTask?.cancel()
        gitRefreshLoopTask?.cancel()
        unreadRefreshLoopTask?.cancel()
        refreshTask?.cancel()
        threadRefreshLoopTask = nil
        gitRefreshLoopTask = nil
        unreadRefreshLoopTask = nil
        refreshTask = nil
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
        guard !isPerformingAction, let dashboardHost else { return }
        isPerformingAction = true
        dashboardHost.prepareForRestart()
        connectionState = .checking
        sessionError = nil
        defer { isPerformingAction = false }
        await cancelRefresh()
        var rendererAvailable = false

        do {
            let targets = try await dashboardHost.restartApplication()
            rendererAvailable = true
            try await refreshThreadSnapshot()
            try await dashboardHost.mountDashboard(
                with: DashboardPayload(threads: threads),
                on: targets,
                force: true
            )
            connectionState = .dashboardMounted
        } catch {
            setFailure(
                error,
                lastKnownState: rendererAvailable ? .rendererAvailable : .appClosed
            )
        }
    }

    func disableDashboard() async {
        guard !isPerformingAction, let dashboardHost else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        await cancelRefresh()

        do {
            switch try await dashboardHost.disableDashboard() {
            case .applicationClosed:
                connectionState = .appClosed
            case .rendererAvailable:
                connectionState = .rendererAvailable
            }
            sessionError = nil
        } catch {
            setFailure(error, lastKnownState: .dashboardMounted)
        }
    }

    func openDashboard() async {
        await dashboardHost?.openDashboard()
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
        unreadRefreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUnreadState()
                try? await Task.sleep(for: .milliseconds(500))
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
            let dashboardHost
        else { return }

        let appIsRunning = dashboardHost.applicationIsRunning
        let targets = await dashboardHost.mainRendererTargets()
        guard !Task.isCancelled, !isPerformingAction else { return }

        if dashboardHost.keepsDashboardMounted, !targets.isEmpty {
            do {
                try await dashboardHost.mountDashboard(
                    with: DashboardPayload(threads: threads),
                    on: targets,
                    force: false
                )
                connectionState = .dashboardMounted
                sessionError = nil
            } catch {
                guard !Task.isCancelled, dashboardHost.keepsDashboardMounted else { return }
                setFailure(error, lastKnownState: .rendererAvailable)
            }
            return
        }
        connectionState = !targets.isEmpty
            ? .rendererAvailable
            : (appIsRunning ? .appRunning : .appClosed)
        sessionError = nil
    }

    private func refreshThreadSnapshot() async throws {
        if let latestUnreadThreadIDs = try? await unreadStateLoader.loadUnreadThreadIDs() {
            unreadThreadIDs = latestUnreadThreadIDs
        }
        let snapshot = try await threadRepository.loadSnapshot(
            gitWorkingTreeStatuses: gitWorkingTreeStatuses,
            activeApplicationLaunchDate: dashboardHost?.applicationLaunchDate
        )
        guard !Task.isCancelled else { return }
        threads = applyingUnreadState(to: snapshot.threads)
        availableThreadCount = snapshot.availableThreadCount
        dataWarning = nil
    }

    private func refreshUnreadState() async {
        guard !isPerformingAction else { return }
        let nextUnreadThreadIDs: Set<String>
        do {
            nextUnreadThreadIDs = try await unreadStateLoader.loadUnreadThreadIDs()
        } catch {
            return
        }
        guard nextUnreadThreadIDs != unreadThreadIDs else { return }
        unreadThreadIDs = nextUnreadThreadIDs

        let updatedThreads = applyingUnreadState(to: threads)
        guard updatedThreads != threads else { return }
        threads = updatedThreads

        guard
            !Task.isCancelled,
            let dashboardHost,
            dashboardHost.keepsDashboardMounted
        else { return }
        let targets = await dashboardHost.mainRendererTargets()
        guard !Task.isCancelled, !targets.isEmpty else { return }
        try? await dashboardHost.mountDashboard(
            with: DashboardPayload(threads: threads),
            on: targets,
            force: false
        )
    }

    private func applyingUnreadState(to sourceThreads: [DashboardThread]) -> [DashboardThread] {
        sourceThreads.map { sourceThread in
            var thread = sourceThread
            thread.isUnread = unreadThreadIDs.contains(thread.id)
            return thread
        }
    }

    private func refreshGitStatuses() async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await refresh() }
        let workspacePaths = Set(threads.map(\.workspacePath))
        guard !workspacePaths.isEmpty, !Task.isCancelled else { return }
        gitWorkingTreeStatuses = await gitStatusLoader.load(at: workspacePaths)
        guard !Task.isCancelled else { return }
        await refresh()
    }

    private var activitySummary: String {
        let runningCount = threads.count { $0.activity == .running }
        return "\(runningCount) running · \(availableThreadCount) available threads"
    }

    private func cancelRefresh() async {
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        await task?.value
    }

    private func setFailure(_ error: Error, lastKnownState: DashboardConnectionState) {
        connectionState = lastKnownState
        sessionError = error.localizedDescription
    }
}
