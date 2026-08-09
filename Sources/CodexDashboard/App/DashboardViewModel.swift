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
final class DashboardViewModel: ObservableObject {
    @Published private(set) var connectionState: DashboardConnectionState = .checking
    @Published private(set) var connectionError: String?
    @Published private(set) var isPerformingAction = false
    @Published private(set) var threadDataWarning: String?
    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var totalThreadCount = 0
    @Published private(set) var compatibilityReport: CompatibilityReport?
    @Published private(set) var isCheckingCompatibility = false
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var lastCompatibilityCheck: Date?
    @Published private(set) var lastErrorDate: Date?
    @Published private(set) var rendererTargetCount = 0
    @Published private(set) var compatibilityWasTriggeredByUpdate = false
    @Published private(set) var completionNotificationsEnabled: Bool

    private let threadSnapshots: ThreadSnapshotService
    private let compatibilityChecker: any LocalCompatibilityChecking
    private let completionNotifier: any ThreadCompletionNotifying
    private let userDefaults: UserDefaults
    private let pollingController = DashboardPollingController()
    private var completionDetector = ThreadCompletionDetector()
    private var runtime: (any DashboardRuntime)?
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
        workingTreeStatusProvider: any WorkingTreeStatusProviding = SystemWorkingTreeStatusProvider(),
        unreadIDProvider: any UnreadThreadIDProviding = CodexUnreadThreadIDProvider(),
        compatibilityChecker: any LocalCompatibilityChecking = LocalCodexCompatibilityChecker(),
        completionNotifier: any ThreadCompletionNotifying = DisabledThreadCompletionNotifier(),
        userDefaults: UserDefaults = .standard,
        runtimeFactory: () throws -> any DashboardRuntime = { try LiveDashboardRuntime() }
    ) {
        threadSnapshots = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadIDProvider: unreadIDProvider
        )
        self.compatibilityChecker = compatibilityChecker
        self.completionNotifier = completionNotifier
        self.userDefaults = userDefaults
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
        let currentVersion = CodexConfiguration.installedVersion
        let previousVersion = UserDefaults.standard.string(forKey: "lastCheckedCodexVersion")
        compatibilityWasTriggeredByUpdate = previousVersion != nil
            && currentVersion != nil
            && previousVersion != currentVersion
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
        Task { await checkCompatibilityAfterVersionChange() }
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
        connectionState = .checking
        connectionError = nil
        defer { isPerformingAction = false }
        await cancelSynchronization()
        var rendererAvailable = false

        do {
            let targets = try await runtime.restartCodex()
            rendererAvailable = true
            try await loadThreadSnapshot()
            try await runtime.synchronizeDashboard(
                with: DashboardSnapshot(threads: threads, totalThreadCount: totalThreadCount),
                on: targets,
                forceRemount: true
            )
            connectionState = .dashboardMounted
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
                connectionState = .codexClosed
            case .rendererReady:
                connectionState = .rendererReady
            }
            connectionError = nil
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
        if let version = CodexConfiguration.installedVersion {
            UserDefaults.standard.set(version, forKey: "lastCheckedCodexVersion")
        }
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
        rendererTargetCount = targets.count
        guard !Task.isCancelled, !isPerformingAction else { return }

        if compatibilityWasTriggeredByUpdate && isCheckingCompatibility {
            connectionState = targets.isEmpty ? .codexRunningWithoutRenderer : .rendererReady
            return
        }
        if let compatibilityReport, compatibilityReport.blockingCount > 0 {
            connectionState = targets.isEmpty ? .codexRunningWithoutRenderer : .rendererReady
            connectionError = "The dashboard was not mounted because a required Codex contract is incompatible. Review Compatibility details."
            return
        }

        if runtime.maintainsDashboard, !targets.isEmpty {
            do {
                try await runtime.synchronizeDashboard(
                    with: DashboardSnapshot(threads: threads, totalThreadCount: totalThreadCount),
                    on: targets,
                    forceRemount: false
                )
                connectionState = .dashboardMounted
                connectionError = nil
            } catch {
                guard !Task.isCancelled, runtime.maintainsDashboard else { return }
                setFailure(error, lastKnownState: .rendererReady)
            }
            return
        }
        connectionState = !targets.isEmpty
            ? .rendererReady
            : (codexIsRunning ? .codexRunningWithoutRenderer : .codexClosed)
        connectionError = nil
    }

    private func loadThreadSnapshot() async throws {
        let snapshot = try await threadSnapshots.loadSnapshot(codexLaunchDate: runtime?.codexLaunchDate)
        guard !Task.isCancelled else { return }
        setThreads(snapshot.catalog.threads)
        totalThreadCount = snapshot.catalog.totalThreadCount
        catalogWarning = nil
        unreadStateWarning = snapshot.unreadStateWarning
        refreshThreadDataWarning()
        lastSuccessfulRefresh = .now
    }

    private func updateUnreadState() async {
        guard !isPerformingAction else { return }
        let generation = enrichmentGeneration
        let refresh = await threadSnapshots.updateUnreadState(in: threads)
        guard !isPerformingAction, generation == enrichmentGeneration else { return }
        unreadStateWarning = refresh.warning
        refreshThreadDataWarning()
        guard let updatedThreads = refresh.threads else { return }
        let unreadByID = Dictionary(uniqueKeysWithValues: updatedThreads.map { ($0.id, $0.isUnread) })
        setThreads(threads.map { source in
            var thread = source
            thread.isUnread = unreadByID[thread.id] ?? thread.isUnread
            return thread
        })
        await publishSnapshotIfMaintained()
    }

    private func updateWorkingTreeStatuses() async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await synchronizeDashboard() }
        let generation = enrichmentGeneration
        guard let updatedThreads = await threadSnapshots.updateWorkingTreeStatuses(in: threads) else { return }
        guard !isPerformingAction, generation == enrichmentGeneration else { return }
        let statusByID = Dictionary(
            uniqueKeysWithValues: updatedThreads.map { ($0.id, $0.workingTreeStatus) }
        )
        setThreads(threads.map { source in
            var thread = source
            thread.workingTreeStatus = statusByID[thread.id] ?? thread.workingTreeStatus
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
            with: DashboardSnapshot(threads: threads, totalThreadCount: totalThreadCount),
            on: targets,
            forceRemount: false
        )
    }

    private func setFailure(_ error: Error, lastKnownState: DashboardConnectionState) {
        connectionState = lastKnownState
        connectionError = error.localizedDescription
        lastErrorDate = .now
    }

    private func refreshThreadDataWarning() {
        let warnings = [catalogWarning, unreadStateWarning].compactMap { $0 }
        threadDataWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    func copyDiagnostics() {
        let formatter = ISO8601DateFormatter()
        let dashboardVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let codexVersion = CodexConfiguration.installedVersion ?? "not found"
        let refreshDate = lastSuccessfulRefresh.map(formatter.string(from:)) ?? "never"
        let compatibilityDate = lastCompatibilityCheck.map(formatter.string(from:)) ?? "never"
        let compatibilitySummary = compatibilityReport?.summary ?? "not checked"
        let currentConnectionError = connectionError ?? "none"
        let currentThreadWarning = threadDataWarning ?? "none"
        let lines = [
            "Codex Dashboard \(dashboardVersion)",
            "Codex: \(codexVersion)",
            "Status: \(statusPresentation.title)",
            "Renderer targets: \(rendererTargetCount)",
            "Threads: \(threads.count) loaded / \(totalThreadCount) total",
            "Last refresh: \(refreshDate)",
            "Last compatibility check: \(compatibilityDate)",
            "Compatibility: \(compatibilitySummary)",
            "Connection error: \(currentConnectionError)",
            "Thread warning: \(currentThreadWarning)",
            "Prompt backup: ~/Library/Application Support/Codex Dashboard/prompt-library.json",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func checkCompatibilityAfterVersionChange() async {
        let currentVersion = CodexConfiguration.installedVersion
        let previousVersion = UserDefaults.standard.string(forKey: "lastCheckedCodexVersion")
        compatibilityWasTriggeredByUpdate = previousVersion != nil
            && currentVersion != nil
            && previousVersion != currentVersion
        await checkCompatibility()
    }
}
