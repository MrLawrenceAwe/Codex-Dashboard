import AppKit
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    static let foregroundOnTaskCompletionKey = "foregroundOnTaskCompletion"

    @Published private(set) var connectionState: DashboardConnectionState = .checking
    @Published private(set) var connectionError: String?
    @Published var isPerformingAction = false
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
    @Published var promptLibraryStatusMessage: String?
    @Published var savedAccounts: [SavedAccount] = []
    @Published var activeAccountID: UUID?
    @Published var accountStatusMessage: String?
    @Published var usageByAccountID: [UUID: CodexAccountUsageSnapshot] = [:]
    @Published var activeAccountUsageStatus: CodexAccountUsageStatus = .unavailable
    @Published var foregroundOnTaskCompletion: Bool {
        didSet { userDefaults.set(foregroundOnTaskCompletion, forKey: Self.foregroundOnTaskCompletionKey) }
    }

    let threadSnapshotService: ThreadSnapshotService
    let compatibilityMonitor: CompatibilityMonitor
    let pollingController: PollingController
    private let userDefaults: UserDefaults
    let codexForegrounder: any CodexForegrounding
    let promptLibraryStore: PromptLibraryFileStore
    let accountManager: CodexAccountManager
    let accountUsageSession: AccountUsageSession
    let synchronizationGate = SynchronizationGate()
    var dashboardRuntime: (any DashboardRuntime)?
    var refreshGeneration = 0
    var catalogWarning: String?
    var unreadStateWarning: String?
    private var activationObserver: NSObjectProtocol?
    var taskCompletionObserver = TaskCompletionObserver()

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
        codexForegrounder: any CodexForegrounding = CodexApplicationForegroundController(),
        promptLibraryStore: PromptLibraryFileStore = PromptLibraryFileStore(),
        accountManager: CodexAccountManager = CodexAccountManager(),
        accountUsageProvider: any AccountUsageProviding = AppServerUsageProvider(),
        accountUsageCacheStore: UsageCache? = nil,
        runtimeFactory: () throws -> any DashboardRuntime = { try LocalCodexDashboardRuntime() }
    ) {
        threadSnapshotService = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: unreadThreadIDProvider
        )
        self.userDefaults = userDefaults
        self.codexForegrounder = codexForegrounder
        self.promptLibraryStore = promptLibraryStore
        self.accountManager = accountManager
        accountUsageSession = AccountUsageSession(
            provider: accountUsageProvider,
            cache: accountUsageCacheStore ?? accountManager.usageCacheStore
        )
        foregroundOnTaskCompletion = userDefaults.object(forKey: Self.foregroundOnTaskCompletionKey) as? Bool ?? true
        pollingController = PollingController(observeFileChanges: observeFileChanges)
        compatibilityMonitor = CompatibilityMonitor(
            localChecker: compatibilityChecker,
            userDefaults: userDefaults,
            installedVersion: installedCodexVersion
        )
        do {
            dashboardRuntime = try runtimeFactory()
        } catch {
            setFailure(error, lastKnownState: .codexClosed)
        }
        usageByAccountID = accountUsageSession.loadCache()
        refreshAccountState()
        if let activeAccountID,
           let snapshot = usageByAccountID[activeAccountID] {
            activeAccountUsageStatus = .stale(snapshot)
        }
    }

    func startMonitoring() {
        compatibilityWasTriggeredByUpdate = compatibilityMonitor.updateWasDetected
        pollingController.start(
            synchronizeDashboard: { [weak self] in await self?.synchronizeDashboard() },
            updateWorkingTrees: { [weak self] paths in
                await self?.updateWorkingTreeStatuses(projectPaths: paths)
            },
            updateUnreadState: { [weak self] in await self?.refreshUnreadState() },
            refreshAccountUsage: { [weak self] in await self?.refreshAccountUsage() }
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
        persistAccountUsageCache(force: true)
        pollingController.stop()
        synchronizationGate.stop()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func synchronizeDashboard() async {
        guard !isPerformingAction else { return }
        refreshAccountState()
        await synchronizationGate.perform { [weak self] in await self?.synchronizeRuntime() }
    }

    func restartCodexAndEnableThreadDashboard() async {
        guard !isPerformingAction, let dashboardRuntime else { return }
        await checkCompatibility()
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
                with: dashboardSnapshotPayload(),
                on: targets,
                forceRemount: true
            )
            setConnectionState(.dashboardMounted)
        } catch {
            setFailure(
                error,
                lastKnownState: rendererAvailable ? .rendererAvailable : .codexClosed
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
            case .rendererAvailable:
                setConnectionState(.rendererAvailable)
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
