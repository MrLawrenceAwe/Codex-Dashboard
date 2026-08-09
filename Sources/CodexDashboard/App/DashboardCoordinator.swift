import AppKit
import Foundation

enum DashboardConnectionState: Equatable {
    case checking
    case codexClosed
    case codexRunningWithoutRenderer
    case rendererReady
    case dashboardMounted

    var rendererIsAvailable: Bool {
        self == .rendererReady || self == .dashboardMounted
    }

    var dashboardIsMounted: Bool {
        self == .dashboardMounted
    }
}

@MainActor
final class DashboardCoordinator: ObservableObject {
    @Published private(set) var connectionState: DashboardConnectionState = .checking
    @Published private(set) var connectionError: String?
    @Published private(set) var isPerformingAction = false
    @Published private(set) var threadDataWarning: String?
    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var totalThreadCount = 0
    @Published private(set) var compatibilityReport: CompatibilityReport?
    @Published private(set) var isCheckingCompatibility = false
    private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var lastCompatibilityCheck: Date?
    @Published private(set) var lastErrorDate: Date?
    @Published private(set) var rendererTargetCount = 0
    @Published private(set) var compatibilityWasTriggeredByUpdate = false
    @Published private(set) var completionNotificationsEnabled: Bool

    private let threadSnapshots: ThreadSnapshotService
    private let compatibilityChecker: any LocalCompatibilityChecking
    private let completionNotifier: any ThreadCompletionNotifying
    private let userDefaults: UserDefaults
    private let versionTracker: CodexVersionCompatibilityTracker
    private let pollingController = DashboardPollingController()
    private var completionDetector = ThreadCompletionDetector()
    private var runtime: (any DashboardSession)?
    private var synchronizationTask: Task<Void, Never>?
    private var synchronizationID: UUID?
    private var enrichmentGeneration = 0
    private var catalogWarning: String?
    private var unreadStateWarning: String?
    private var activationObserver: NSObjectProtocol?

    var statusPresentation: (title: String, detail: String) {
        if connectionError != nil {
            return ("Thread Dashboard needs attention", "Review the message below and try again.")
        }
        return switch connectionState {
        case .checking:
            ("Checking Codex…", "Looking for the local Codex app.")
        case .codexClosed:
            ("Codex is closed", "The Thread Dashboard can relaunch it with local debugging enabled.")
        case .codexRunningWithoutRenderer:
            (
                "Codex is running without the Thread Dashboard connection",
                "Restart it through this controller once to enable the Thread Dashboard."
            )
        case .rendererReady:
            ("Thread Dashboard is ready", "The local renderer is connected and ready.")
        case .dashboardMounted:
            ("Thread Dashboard is live", connectionSummary)
        }
    }

    init(
        catalogProvider: any ThreadCatalogProviding = CodexThreadCatalogProvider(),
        workingTreeStatusProvider: any WorkingTreeStatusProviding = GitWorkingTreeStatusProvider(),
        unreadThreadIDProvider: any UnreadThreadIDProviding = CodexUnreadThreadIDProvider(),
        compatibilityChecker: any LocalCompatibilityChecking = LocalCodexCompatibilityChecker(),
        completionNotifier: any ThreadCompletionNotifying = DisabledThreadCompletionNotifier(),
        userDefaults: UserDefaults = .standard,
        runtimeFactory: () throws -> any DashboardSession = { try LiveDashboardSession() }
    ) {
        threadSnapshots = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: unreadThreadIDProvider
        )
        self.compatibilityChecker = compatibilityChecker
        self.completionNotifier = completionNotifier
        self.userDefaults = userDefaults
        versionTracker = CodexVersionCompatibilityTracker(userDefaults: userDefaults)
        completionNotificationsEnabled = userDefaults.object(
            forKey: "completionNotificationsEnabled"
        ) as? Bool ?? true
        do {
            runtime = try runtimeFactory()
        } catch {
            setFailure(error, lastKnownState: .codexClosed)
        }
    }

    deinit {
        synchronizationTask?.cancel()
    }

    func startMonitoring() {
        if completionNotificationsEnabled {
            completionNotifier.requestAuthorization()
        }
        compatibilityWasTriggeredByUpdate = versionTracker.updateWasDetected(
            currentVersion: CodexConfiguration.installedVersion
        )
        pollingController.start(
            synchronizeDashboard: { [weak self] in await self?.synchronizeDashboard() },
            updateWorkingTrees: { [weak self] in await self?.updateWorkingTreeStatuses() },
            updateUnreadState: { [weak self] in await self?.updateUnreadState() }
        )
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.synchronizeDashboard() }
            }
        }
        Task { await checkCompatibility() }
    }

    func setCompletionNotificationsEnabled(_ enabled: Bool) {
        completionNotificationsEnabled = enabled
        userDefaults.set(enabled, forKey: "completionNotificationsEnabled")
        if enabled {
            completionNotifier.requestAuthorization()
        }
    }

    func stopMonitoring() {
        enrichmentGeneration += 1
        pollingController.stop()
        synchronizationTask?.cancel()
        synchronizationTask = nil
        synchronizationID = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func synchronizeDashboard() async {
        guard !isPerformingAction else { return }
        if let synchronizationTask {
            await synchronizationTask.value
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.synchronizeRuntime()
        }
        synchronizationTask = task
        synchronizationID = taskID
        await task.value
        if synchronizationID == taskID {
            synchronizationTask = nil
            synchronizationID = nil
        }
    }

    func restartCodexAndEnableThreadDashboard() async {
        guard !isPerformingAction, let runtime else { return }
        isPerformingAction = true
        enrichmentGeneration += 1
        runtime.prepareForRestart()
        setConnectionState(.checking)
        setConnectionError(nil)
        defer { isPerformingAction = false }
        await cancelSynchronization()
        var rendererAvailable = false

        do {
            let targets = try await runtime.restartCodex()
            rendererAvailable = true
            try await loadThreadSnapshot()
            try await runtime.synchronizeDashboard(
                with: DashboardSnapshotPayload(threads: threads, totalThreadCount: totalThreadCount),
                on: targets,
                forceRemount: true
            )
            setConnectionState(.dashboardMounted)
        } catch {
            setFailure(
                error,
                lastKnownState: rendererAvailable ? .rendererReady : .codexClosed
            )
        }
    }

    func disableThreadDashboard() async {
        guard !isPerformingAction, let runtime else { return }
        isPerformingAction = true
        enrichmentGeneration += 1
        defer { isPerformingAction = false }
        await cancelSynchronization()

        do {
            switch try await runtime.disableThreadDashboard() {
            case .codexClosed:
                setConnectionState(.codexClosed)
            case .rendererReady:
                setConnectionState(.rendererReady)
            }
            setConnectionError(nil)
        } catch {
            setFailure(error, lastKnownState: .dashboardMounted)
        }
    }

    func openThreadDashboard() async {
        await runtime?.openThreadDashboard()
    }

    func checkCompatibility() async {
        guard !isCheckingCompatibility else { return }
        isCheckingCompatibility = true
        defer { isCheckingCompatibility = false }

        async let localChecks = compatibilityChecker.checkLocalContracts()
        let rendererChecks: [CompatibilityCheck]
        if let runtime {
            rendererChecks = await runtime.rendererCompatibilityChecks()
        } else {
            rendererChecks = [CompatibilityCheck(
                id: "renderer",
                title: "Renderer connection",
                status: .unavailable,
                detail: "The dashboard runtime is unavailable."
            )]
        }
        compatibilityReport = CompatibilityReport(checks: await localChecks + rendererChecks)
        lastCompatibilityCheck = .now
        versionTracker.markChecked(version: CodexConfiguration.installedVersion)
    }

    private func synchronizeRuntime() async {
        do {
            try await loadThreadSnapshot()
        } catch {
            catalogWarning = "Thread data could not be refreshed. Showing the last successful snapshot. \(error.localizedDescription)"
            refreshThreadDataWarning()
        }

        guard !Task.isCancelled, !isPerformingAction, let runtime else { return }

        let codexIsRunning = runtime.codexIsRunning
        let targets = await runtime.rendererTargets()
        if rendererTargetCount != targets.count {
            rendererTargetCount = targets.count
        }
        guard !Task.isCancelled, !isPerformingAction else { return }

        if compatibilityWasTriggeredByUpdate && isCheckingCompatibility {
            setConnectionState(targets.isEmpty ? .codexRunningWithoutRenderer : .rendererReady)
            return
        }
        if let compatibilityReport, compatibilityReport.blockingCount > 0 {
            setConnectionState(targets.isEmpty ? .codexRunningWithoutRenderer : .rendererReady)
            setConnectionError("The dashboard was not mounted because a required Codex contract is incompatible. Review Compatibility details.")
            return
        }

        if runtime.maintainsDashboard, !targets.isEmpty {
            do {
                try await runtime.synchronizeDashboard(
                    with: DashboardSnapshotPayload(threads: threads, totalThreadCount: totalThreadCount),
                    on: targets,
                    forceRemount: false
                )
                setConnectionState(.dashboardMounted)
                setConnectionError(nil)
            } catch {
                guard !Task.isCancelled, runtime.maintainsDashboard else { return }
                setFailure(error, lastKnownState: .rendererReady)
            }
            return
        }
        setConnectionState(!targets.isEmpty
            ? .rendererReady
            : (codexIsRunning ? .codexRunningWithoutRenderer : .codexClosed))
        setConnectionError(nil)
    }

    private func loadThreadSnapshot() async throws {
        let snapshot = try await threadSnapshots.loadSnapshot(codexLaunchDate: runtime?.codexLaunchDate)
        guard !Task.isCancelled else { return }
        setThreads(snapshot.catalog.threads)
        if totalThreadCount != snapshot.catalog.totalThreadCount {
            totalThreadCount = snapshot.catalog.totalThreadCount
        }
        catalogWarning = nil
        unreadStateWarning = snapshot.unreadStateWarning
        refreshThreadDataWarning()
        lastSuccessfulRefresh = .now
    }

    private func updateUnreadState() async {
        guard !isPerformingAction else { return }
        let generation = enrichmentGeneration
        let refresh = await threadSnapshots.updateUnreadState()
        guard !isPerformingAction, generation == enrichmentGeneration else { return }
        unreadStateWarning = refresh.warning
        refreshThreadDataWarning()
        guard let unreadThreadIDs = refresh.unreadThreadIDs else { return }
        setThreads(threads.map { source in
            var thread = source
            thread.isUnread = unreadThreadIDs.contains(thread.id)
            return thread
        })
        await publishSnapshotIfMaintained()
    }

    private func updateWorkingTreeStatuses() async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await synchronizeDashboard() }
        let generation = enrichmentGeneration
        guard let statusByProjectPath = await threadSnapshots.updateWorkingTreeStatuses(in: threads) else { return }
        guard !isPerformingAction, generation == enrichmentGeneration else { return }
        setThreads(threads.map { source in
            var thread = source
            thread.workingTreeStatus = statusByProjectPath[thread.projectPath] ?? .notRepository
            return thread
        })
        await publishSnapshotIfMaintained()
    }

    private func setThreads(_ updatedThreads: [ThreadSummary]) {
        let completedThreads = completionDetector.observe(updatedThreads)
        if threads != updatedThreads {
            threads = updatedThreads
        }
        guard completionNotificationsEnabled else { return }
        for thread in completedThreads {
            completionNotifier.postCompletion(for: thread)
        }
    }

    private var connectionSummary: String {
        let runningCount = threads.count { $0.runState == .running }
        return "\(runningCount) running · \(totalThreadCount) available threads"
    }

    private func cancelSynchronization() async {
        let task = synchronizationTask
        synchronizationTask = nil
        synchronizationID = nil
        task?.cancel()
        await task?.value
    }

    private func publishSnapshotIfMaintained() async {
        guard
            !Task.isCancelled,
            !isPerformingAction,
            let runtime,
            runtime.maintainsDashboard
        else { return }
        let targets = await runtime.rendererTargets()
        guard !Task.isCancelled, !targets.isEmpty else { return }
        try? await runtime.synchronizeDashboard(
            with: DashboardSnapshotPayload(threads: threads, totalThreadCount: totalThreadCount),
            on: targets,
            forceRemount: false
        )
    }

    private func setFailure(_ error: Error, lastKnownState: DashboardConnectionState) {
        setConnectionState(lastKnownState)
        setConnectionError(error.localizedDescription)
        lastErrorDate = .now
    }

    private func refreshThreadDataWarning() {
        let warnings = [catalogWarning, unreadStateWarning].compactMap { $0 }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        if threadDataWarning != warning {
            threadDataWarning = warning
        }
    }

    private func setConnectionState(_ state: DashboardConnectionState) {
        if connectionState != state {
            connectionState = state
        }
    }

    private func setConnectionError(_ error: String?) {
        if connectionError != error {
            connectionError = error
        }
    }

    func copyDiagnostics() {
        let diagnostics = DashboardDiagnostics(
            dashboardVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            codexVersion: CodexConfiguration.installedVersion ?? "not found",
            status: statusPresentation.title,
            rendererTargetCount: rendererTargetCount,
            loadedThreadCount: threads.count,
            totalThreadCount: totalThreadCount,
            lastRefresh: lastSuccessfulRefresh,
            lastCompatibilityCheck: lastCompatibilityCheck,
            compatibilitySummary: compatibilityReport?.summary ?? "not checked",
            connectionError: connectionError,
            threadWarning: threadDataWarning,
            promptBackupPath: "~/Library/Application Support/Codex Dashboard/prompt-library.json"
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.text, forType: .string)
    }
}
