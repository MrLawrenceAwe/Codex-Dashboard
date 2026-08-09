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
    @Published private(set) var connectionError: String?
    @Published private(set) var isPerformingAction = false
    @Published private(set) var threadDataWarning: String?
    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var totalThreadCount = 0

    private let threadService: ThreadDashboardService
    private let refreshCoordinator = DashboardRefreshCoordinator()
    private var runtime: (any DashboardRuntime)?
    private var refreshTask: Task<Void, Never>?

    var statusPresentation: (title: String, detail: String) {
        if connectionError != nil {
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
            ("Dashboard is live", connectionSummary)
        }
    }

    init(
        catalogProvider: any ThreadCatalogProviding = CodexThreadCatalogProvider(),
        gitStatusProvider: any GitStatusProviding = SystemGitStatusProvider(),
        unreadIDProvider: any UnreadThreadIDProviding = CodexUnreadThreadIDProvider(),
        runtimeFactory: () throws -> any DashboardRuntime = { try DashboardRuntimeCoordinator() }
    ) {
        threadService = ThreadDashboardService(
            catalogProvider: catalogProvider,
            gitStatusProvider: gitStatusProvider,
            unreadIDProvider: unreadIDProvider
        )
        do {
            runtime = try runtimeFactory()
        } catch {
            setFailure(error, lastKnownState: .appClosed)
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func startRefreshing() {
        refreshCoordinator.start(
            refreshThreads: { [weak self] in await self?.refresh() },
            refreshGit: { [weak self] in await self?.refreshGitStatuses() },
            refreshUnread: { [weak self] in await self?.refreshUnreadState() }
        )
    }

    func stopRefreshing() {
        refreshCoordinator.stop()
        refreshTask?.cancel()
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
            await self.synchronizeRuntime()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func restartCodexAndEnableDashboard() async {
        guard !isPerformingAction, let runtime else { return }
        isPerformingAction = true
        runtime.prepareForRestart()
        connectionState = .checking
        connectionError = nil
        defer { isPerformingAction = false }
        await cancelRefresh()
        var rendererAvailable = false

        do {
            let targets = try await runtime.restartCodex()
            rendererAvailable = true
            try await loadThreadCatalog()
            try await runtime.synchronizeDashboard(
                with: RendererSnapshot(threads: threads),
                on: targets,
                forceRemount: true
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
        guard !isPerformingAction, let runtime else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        await cancelRefresh()

        do {
            switch try await runtime.disableDashboard() {
            case .codexClosed:
                connectionState = .appClosed
            case .rendererAvailable:
                connectionState = .rendererAvailable
            }
            connectionError = nil
        } catch {
            setFailure(error, lastKnownState: .dashboardMounted)
        }
    }

    func openDashboard() async {
        await runtime?.openDashboard()
    }

    private func synchronizeRuntime() async {
        do {
            try await loadThreadCatalog()
        } catch {
            threadDataWarning = "Thread data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)"
        }

        guard !Task.isCancelled, !isPerformingAction, let runtime else { return }

        let codexIsRunning = runtime.codexIsRunning
        let targets = await runtime.rendererTargets()
        guard !Task.isCancelled, !isPerformingAction else { return }

        if runtime.maintainsDashboard, !targets.isEmpty {
            do {
                try await runtime.synchronizeDashboard(
                    with: RendererSnapshot(threads: threads),
                    on: targets,
                    forceRemount: false
                )
                connectionState = .dashboardMounted
                connectionError = nil
            } catch {
                guard !Task.isCancelled, runtime.maintainsDashboard else { return }
                setFailure(error, lastKnownState: .rendererAvailable)
            }
            return
        }
        connectionState = !targets.isEmpty
            ? .rendererAvailable
            : (codexIsRunning ? .appRunning : .appClosed)
        connectionError = nil
    }

    private func loadThreadCatalog() async throws {
        let catalog = try await threadService.loadCatalog(codexLaunchDate: runtime?.codexLaunchDate)
        guard !Task.isCancelled else { return }
        threads = catalog.threads
        totalThreadCount = catalog.totalThreadCount
        threadDataWarning = nil
    }

    private func refreshUnreadState() async {
        guard
            !isPerformingAction,
            let updatedThreads = await threadService.refreshUnreadState(in: threads)
        else { return }
        threads = updatedThreads

        guard
            !Task.isCancelled,
            let runtime,
            runtime.maintainsDashboard
        else { return }
        let targets = await runtime.rendererTargets()
        guard !Task.isCancelled, !targets.isEmpty else { return }
        try? await runtime.synchronizeDashboard(
            with: RendererSnapshot(threads: threads),
            on: targets,
            forceRemount: false
        )
    }

    private func refreshGitStatuses() async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await refresh() }
        if await threadService.refreshGitStatuses(for: threads) {
            await refresh()
        }
    }

    private var connectionSummary: String {
        let runningCount = threads.count { $0.runState == .running }
        return "\(runningCount) running · \(totalThreadCount) available threads"
    }

    private func cancelRefresh() async {
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        await task?.value
    }

    private func setFailure(_ error: Error, lastKnownState: DashboardConnectionState) {
        connectionState = lastKnownState
        connectionError = error.localizedDescription
    }
}
