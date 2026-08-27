import AppKit
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    static let foregroundOnTaskCompletionKey = "foregroundOnTaskCompletion"

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
    @Published private(set) var promptLibraryStatusMessage: String?
    @Published private(set) var savedAccounts: [SavedAccount] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var accountStatusMessage: String?
    @Published private(set) var usageByAccountID: [UUID: CodexAccountUsageSnapshot] = [:]
    @Published private(set) var activeAccountUsageStatus: CodexAccountUsageStatus = .unavailable
    @Published private(set) var refreshingUsageAccountIDs: Set<UUID> = []
    @Published private(set) var usageErrorsByAccountID: [UUID: String] = [:]
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
    private(set) var dashboardRuntime: (any DashboardRuntime)?
    private(set) var refreshGeneration = 0
    private(set) var catalogWarning: String?
    private(set) var unreadStateWarning: String?
    private var activationObserver: NSObjectProtocol?
    private var taskCompletionObserver = TaskCompletionObserver()

    var statusPresentation: (title: String, detail: String) {
        connectionState.presentation(
            hasError: connectionError != nil,
            mountedSummary: connectionSummary
        )
    }

    var dashboardActions: DashboardActionPresentation {
        DashboardActionPresentation(
            connectionState: connectionState,
            isPerformingAction: isPerformingAction,
            isCheckingCompatibility: isCheckingCompatibility
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
            refreshAccountUsage: { [weak self] in await self?.refreshAccountUsage() },
            refreshInactiveAccountUsage: {
                [weak self] in await self?.refreshInactiveAccountUsage()
            },
            handleAccountPopoverAction: { [weak self] in
                await self?.handleAccountPopoverAction() ?? .unavailable
            },
            refreshAccountState: { [weak self] in
                await self?.refreshAccountStateAfterFileChange()
            }
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
        await synchronizationGate.perform { [weak self] in await self?.synchronizeRuntime() }
    }

    func restartCodexAndEnableThreadDashboard() async {
        guard !isPerformingAction, let dashboardRuntime else { return }
        do {
            try await loadThreadSnapshot()
        } catch {
            setConnectionError(
                "Codex was not restarted because active tasks could not be checked. "
                    + error.localizedDescription
            )
            return
        }
        guard !threads.contains(where: { $0.runState == .running }) else {
            setConnectionError("Finish or cancel active Codex tasks before restarting.")
            return
        }
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

    func setPerformingAction(_ value: Bool) {
        isPerformingAction = value
    }

    func advanceRefreshGeneration() {
        refreshGeneration += 1
    }

    func setCompatibilityChecking(_ value: Bool) {
        isCheckingCompatibility = value
    }

    func setCompatibilityReport(_ report: CompatibilityReport, checkedAt: Date = .now) {
        compatibilityReport = report
        lastCompatibilityCheck = checkedAt
    }

    func setRendererTargetCount(_ count: Int) {
        if rendererTargetCount != count { rendererTargetCount = count }
    }

    func setPromptLibraryStatus(_ message: String?) {
        promptLibraryStatusMessage = message
    }

    func setAccountStatus(_ message: String?) {
        accountStatusMessage = message
    }

    func setAccountState(accounts: [SavedAccount], activeAccountID: UUID?) {
        if savedAccounts != accounts { savedAccounts = accounts }
        if self.activeAccountID != activeAccountID { self.activeAccountID = activeAccountID }
    }

    func updateUsage(_ snapshot: CodexAccountUsageSnapshot?, for accountID: UUID) {
        usageByAccountID[accountID] = snapshot
    }

    func setActiveAccountUsageStatus(_ status: CodexAccountUsageStatus) {
        activeAccountUsageStatus = status
    }

    func setRefreshingUsage(_ isRefreshing: Bool, for accountID: UUID) {
        if isRefreshing {
            refreshingUsageAccountIDs.insert(accountID)
        } else {
            refreshingUsageAccountIDs.remove(accountID)
        }
    }

    func setUsageError(_ message: String?, for accountID: UUID) {
        usageErrorsByAccountID[accountID] = message
    }

    func setCatalogWarning(_ warning: String?) {
        catalogWarning = warning
    }

    func setUnreadStateWarning(_ warning: String?) {
        unreadStateWarning = warning
    }

    func setThreadSnapshot(
        _ updatedThreads: [ThreadSummary],
        totalCount: Int? = nil,
        refreshedAt: Date? = nil
    ) {
        pollingController.updateProjectPaths(Set(updatedThreads.map(\.projectPath)))
        if threads != updatedThreads { threads = updatedThreads }
        if let totalCount, totalThreadCount != totalCount { totalThreadCount = totalCount }
        if let refreshedAt { lastSuccessfulRefresh = refreshedAt }
    }

    func setThreadDataWarning(_ warning: String?) {
        if threadDataWarning != warning { threadDataWarning = warning }
    }

    func newestCompletedThreadID(in threads: [ThreadSummary]) -> String? {
        taskCompletionObserver.newestCompletion(in: threads)
    }

    static let incompatibleContractMessage =
        "The dashboard was not mounted because a required Codex contract is incompatible. Review Compatibility details."

}
