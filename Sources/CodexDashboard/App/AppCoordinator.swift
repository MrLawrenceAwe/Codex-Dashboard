import AppKit
import Combine
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    static let foregroundOnTaskCompletionKey = "foregroundOnTaskCompletion"

    @Published var connectionState: DashboardConnectionState = .checking
    @Published var connectionError: String?
    @Published var isPerformingAction = false
    @Published var threadDataWarning: String?
    @Published var threads: [ThreadSummary] = []
    @Published var totalThreadCount = 0
    @Published var compatibilityReport: CompatibilityReport?
    @Published var isCheckingCompatibility = false
    var lastSuccessfulRefresh: Date?
    @Published var lastCompatibilityCheck: Date?
    @Published var lastErrorDate: Date?
    @Published var rendererTargetCount = 0
    @Published var compatibilityWasTriggeredByUpdate = false
    @Published var promptLibraryStatusMessage: String?
    @Published var foregroundOnTaskCompletion: Bool {
        didSet { userDefaults.set(foregroundOnTaskCompletion, forKey: Self.foregroundOnTaskCompletionKey) }
    }

    let threadSnapshotService: ThreadSnapshotService
    let compatibilityMonitor: CompatibilityMonitor
    let refreshScheduler: RefreshScheduler
    let accountPopoverActionListener = AccountPopoverActionListener()
    private let userDefaults: UserDefaults
    let codexForegrounder: any CodexForegrounding
    let promptLibraryStore: PromptLibraryFileStore
    let accounts: AccountCoordinator
    let synchronizationGate = SynchronizationGate()
    private(set) var dashboardRuntime: (any DashboardRuntime)?
    var refreshGeneration = 0
    var catalogWarning: String?
    var unreadStateWarning: String?
    private var activationObserver: NSObjectProtocol?
    private var accountStateObserver: AnyCancellable?
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
        accounts = AccountCoordinator(
            manager: accountManager,
            usageProvider: accountUsageProvider,
            usageCacheStore: accountUsageCacheStore
        )
        foregroundOnTaskCompletion = userDefaults.object(forKey: Self.foregroundOnTaskCompletionKey) as? Bool ?? true
        refreshScheduler = RefreshScheduler(observeFileChanges: observeFileChanges)
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
        accountStateObserver = accounts.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func startMonitoring() {
        compatibilityWasTriggeredByUpdate = compatibilityMonitor.updateWasDetected
        refreshScheduler.start(
            synchronizeDashboard: { [weak self] in await self?.synchronizeDashboard() },
            updateWorkingTrees: { [weak self] paths in
                await self?.updateWorkingTreeStatuses(projectPaths: paths)
            },
            updateUnreadState: { [weak self] in await self?.refreshUnreadState() },
            refreshAccountUsage: { [weak self] in await self?.refreshAccountUsage() },
            refreshInactiveAccountUsage: {
                [weak self] in await self?.refreshInactiveAccountUsage()
            },
            refreshAccountState: { [weak self] in
                await self?.refreshAccountStateAfterFileChange()
            }
        )
        accountPopoverActionListener.start { [weak self] in
            await self?.handleAccountPopoverAction() ?? .unavailable
        }
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
        accounts.persistUsageCache(force: true)
        refreshScheduler.stop()
        accountPopoverActionListener.stop()
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

    func restartCodexAndEnableTaskDashboard() async {
        guard !isPerformingAction, let dashboardRuntime else { return }
        do {
            try await loadThreadSnapshot()
        } catch {
            connectionError =
                "Codex was not restarted because active tasks could not be checked. "
                    + error.localizedDescription
            return
        }
        guard !threads.contains(where: { $0.runState == .running }) else {
            connectionError = "Finish or cancel active Codex tasks before restarting."
            return
        }
        await checkCompatibility()
        guard compatibilityReport?.blockingCount ?? 0 == 0 else {
            connectionError = Self.incompatibleContractMessage
            return
        }
        isPerformingAction = true
        refreshGeneration += 1
        dashboardRuntime.prepareForRestart()
        connectionState = .checking
        connectionError = nil
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
            connectionState = .dashboardMounted
        } catch {
            setFailure(
                error,
                lastKnownState: rendererAvailable ? .rendererAvailable : .codexClosed
            )
        }
    }

    func disableTaskDashboard() async {
        guard !isPerformingAction, let dashboardRuntime else { return }
        isPerformingAction = true
        refreshGeneration += 1
        defer { isPerformingAction = false }
        await cancelSynchronization()

        do {
            switch try await dashboardRuntime.disableTaskDashboard() {
            case .codexClosed:
                connectionState = .codexClosed
            case .rendererAvailable:
                connectionState = .rendererAvailable
            }
            connectionError = nil
        } catch {
            setFailure(error, lastKnownState: .dashboardMounted)
        }
    }

    func openTaskDashboard() async {
        await dashboardRuntime?.openTaskDashboard()
    }

    private func cancelSynchronization() async {
        await synchronizationGate.cancel()
    }

    func setFailure(_ error: Error, lastKnownState: DashboardConnectionState) {
        updatePublished(\.connectionState, to: lastKnownState)
        updatePublished(\.connectionError, to: error.localizedDescription)
        lastErrorDate = .now
    }

    func updatePublished<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppCoordinator, Value>,
        to value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    func applyThreadSnapshot(
        _ updatedThreads: [ThreadSummary],
        totalCount: Int? = nil,
        refreshedAt: Date? = nil
    ) {
        refreshScheduler.updateProjectPaths(Set(updatedThreads.map(\.projectPath)))
        if threads != updatedThreads { threads = updatedThreads }
        if let totalCount, totalThreadCount != totalCount { totalThreadCount = totalCount }
        if let refreshedAt { lastSuccessfulRefresh = refreshedAt }
    }

    func newestCompletedThreadID(in threads: [ThreadSummary]) -> String? {
        taskCompletionObserver.newestCompletion(in: threads)
    }

    static let incompatibleContractMessage =
        "The dashboard was not mounted because a required Codex contract is incompatible. Review Compatibility details."

}
