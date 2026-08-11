import AppKit
import Foundation

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

    private let threadSnapshots: ThreadSnapshotService
    private let compatibilityChecker: any LocalCompatibilityChecking
    private let userDefaults: UserDefaults
    private let versionTracker: CodexVersionCompatibilityTracker
    private let installedCodexVersion: () -> String?
    private let pollingController: DashboardPollingController
    private let synchronizationGate = DashboardSynchronizationGate()
    private var runtime: (any DashboardSession)?
    private var enrichmentGeneration = 0
    private var catalogWarning: String?
    private var unreadStateWarning: String?
    private var activationObserver: NSObjectProtocol?

    var statusPresentation: (title: String, detail: String) {
        connectionState.presentation(
            hasError: connectionError != nil,
            mountedSummary: connectionSummary
        )
    }

    init(
        catalogProvider: any ThreadCatalogProviding = CodexThreadCatalogProvider(),
        workingTreeStatusProvider: any WorkingTreeStatusProviding = GitWorkingTreeStatusProvider(),
        unreadThreadIDProvider: any UnreadThreadIDProviding = CodexUnreadThreadIDProvider(),
        compatibilityChecker: any LocalCompatibilityChecking = LocalCodexCompatibilityChecker(),
        userDefaults: UserDefaults = .standard,
        observeFileChanges: Bool = true,
        installedCodexVersion: @escaping () -> String? = { CodexConfiguration.installedVersion },
        runtimeFactory: () throws -> any DashboardSession = { try LiveDashboardSession() }
    ) {
        threadSnapshots = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: unreadThreadIDProvider
        )
        self.compatibilityChecker = compatibilityChecker
        self.userDefaults = userDefaults
        pollingController = DashboardPollingController(observeFileChanges: observeFileChanges)
        self.installedCodexVersion = installedCodexVersion
        versionTracker = CodexVersionCompatibilityTracker(userDefaults: userDefaults)
        do {
            runtime = try runtimeFactory()
        } catch {
            setFailure(error, lastKnownState: .codexClosed)
        }
    }

    func startMonitoring() {
        compatibilityWasTriggeredByUpdate = versionTracker.updateWasDetected(
            currentVersion: installedCodexVersion()
        )
        pollingController.start(
            synchronizeDashboard: { [weak self] in await self?.synchronizeDashboard() },
            updateWorkingTrees: { [weak self] paths in
                await self?.updateWorkingTreeStatuses(projectPaths: paths)
            },
            updateUnreadState: { [weak self] in await self?.refreshUnreadState() }
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

    func stopMonitoring() {
        enrichmentGeneration += 1
        pollingController.stop()
        synchronizationGate.stop()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func synchronizeDashboard() async {
        guard !isPerformingAction else { return }
        await synchronizationGate.perform { [weak self] in await self?.synchronizeRuntime() }
    }

    func restartCodexAndEnableThreadDashboard() async {
        guard !isPerformingAction, let runtime else { return }
        guard compatibilityReport?.blockingCount ?? 0 == 0 else {
            setConnectionError(Self.incompatibleContractMessage)
            return
        }
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
                with: DashboardSnapshotPayload(threads: threads),
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
        if rendererChecks.contains(where: { $0.id == "renderer" && $0.status == .compatible }) {
            versionTracker.markChecked(version: installedCodexVersion())
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
            setConnectionError(Self.incompatibleContractMessage)
            return
        }

        if runtime.maintainsDashboard, !targets.isEmpty {
            do {
                try await runtime.synchronizeDashboard(
                    with: DashboardSnapshotPayload(threads: threads),
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

    func refreshUnreadState() async {
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

    private func updateWorkingTreeStatuses(projectPaths: Set<String>? = nil) async {
        guard !isPerformingAction else { return }
        if threads.isEmpty { await synchronizeDashboard() }
        let generation = enrichmentGeneration
        guard let statusByProjectPath = await threadSnapshots.updateWorkingTreeStatuses(
            in: threads,
            projectPaths: projectPaths
        ) else { return }
        guard !isPerformingAction, generation == enrichmentGeneration else { return }
        setThreads(threads.map { source in
            var thread = source
            if let status = statusByProjectPath[thread.projectPath] {
                thread.workingTreeStatus = status
            }
            return thread
        })
        await publishSnapshotIfMaintained()
    }

    private func setThreads(_ updatedThreads: [ThreadSummary]) {
        pollingController.updateProjectPaths(Set(updatedThreads.map(\.projectPath)))
        if threads != updatedThreads {
            threads = updatedThreads
        }
    }

    private var connectionSummary: String {
        let runningCount = threads.count { $0.runState == .running }
        return "\(runningCount) running · \(totalThreadCount) available threads"
    }

    private func cancelSynchronization() async {
        await synchronizationGate.cancel()
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
            with: DashboardSnapshotPayload(threads: threads),
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

    private static let incompatibleContractMessage =
        "The dashboard was not mounted because a required Codex contract is incompatible. Review Compatibility details."

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
