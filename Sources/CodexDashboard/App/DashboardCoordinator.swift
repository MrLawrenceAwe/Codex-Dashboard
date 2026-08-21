import AppKit
import Foundation

@MainActor
final class DashboardCoordinator: ObservableObject {
    @Published private(set) var connectionState: DashboardConnectionState = .checking
    @Published private(set) var connectionError: String?
    @Published private(set) var isPerformingAction = false
    @Published var threadDataWarning: String?
    @Published var threads: [ThreadSummary] = []
    @Published var totalThreadCount = 0
    @Published var compatibilityReport: CompatibilityReport?
    @Published var isCheckingCompatibility = false
    var lastSuccessfulRefresh: Date?
    @Published var lastCompatibilityCheck: Date?
    @Published private(set) var lastErrorDate: Date?
    @Published var rendererTargetCount = 0
    @Published private(set) var compatibilityWasTriggeredByUpdate = false

    let threadSnapshotService: ThreadSnapshotService
    let compatibilityChecker: any LocalCompatibilityChecking
    let versionTracker: CodexVersionCompatibilityTracker
    let installedCodexVersion: () -> String?
    let pollingController: DashboardPollingController
    private let synchronizationGate = DashboardSynchronizationGate()
    var dashboardRuntime: (any DashboardRuntime)?
    var refreshGeneration = 0
    var catalogWarning: String?
    var unreadStateWarning: String?
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
        runtimeFactory: () throws -> any DashboardRuntime = { try LocalCodexDashboardRuntime() }
    ) {
        threadSnapshotService = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: unreadThreadIDProvider
        )
        self.compatibilityChecker = compatibilityChecker
        pollingController = DashboardPollingController(observeFileChanges: observeFileChanges)
        self.installedCodexVersion = installedCodexVersion
        versionTracker = CodexVersionCompatibilityTracker(userDefaults: userDefaults)
        do {
            dashboardRuntime = try runtimeFactory()
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
                Task { @MainActor in await self?.refreshAfterActivation() }
            }
        }
        Task { await checkCompatibility() }
    }

    func stopMonitoring() {
        refreshGeneration += 1
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
        guard !isPerformingAction, let dashboardRuntime else { return }
        guard compatibilityReport?.blockingCount ?? 0 == 0 else {
            setConnectionError(Self.incompatibleContractMessage)
            return
        }
        isPerformingAction = true
        refreshGeneration += 1
        dashboardRuntime.prepareForRestart()
        setConnectionState(.checking)
        setConnectionError(nil)
        defer { isPerformingAction = false }
        await cancelSynchronization()
        var rendererAvailable = false

        do {
            let targets = try await dashboardRuntime.restartCodex()
            rendererAvailable = true
            try await loadThreadSnapshot()
            try await dashboardRuntime.synchronizeDashboard(
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
        guard !isPerformingAction, let dashboardRuntime else { return }
        isPerformingAction = true
        refreshGeneration += 1
        defer { isPerformingAction = false }
        await cancelSynchronization()

        do {
            switch try await dashboardRuntime.disableThreadDashboard() {
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
        await dashboardRuntime?.openThreadDashboard()
    }

    private func cancelSynchronization() async {
        await synchronizationGate.cancel()
    }

    func setFailure(_ error: Error, lastKnownState: DashboardConnectionState) {
        setConnectionState(lastKnownState)
        setConnectionError(error.localizedDescription)
        lastErrorDate = .now
    }

    func setConnectionState(_ state: DashboardConnectionState) {
        if connectionState != state {
            connectionState = state
        }
    }

    func setConnectionError(_ error: String?) {
        if connectionError != error {
            connectionError = error
        }
    }

    static let incompatibleContractMessage =
        "The dashboard was not mounted because a required Codex contract is incompatible. Review Compatibility details."

}
