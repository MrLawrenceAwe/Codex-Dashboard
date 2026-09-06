import AppKit
import Combine
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    static let completionBehaviorKey = "taskCompletionBehavior"
    static let completionInboxKey = "taskCompletionInbox"
    private static let maximumLiveMonitoredProjectCount = 60

    @Published var connectionState: DashboardConnectionState = .checking
    @Published var connectionError: String?
    @Published var connectionNotice: String?
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
    @Published var completionBehavior: TaskCompletionBehavior {
        didSet { userDefaults.set(completionBehavior.rawValue, forKey: Self.completionBehaviorKey) }
    }
    @Published private(set) var completionInbox: [TaskCompletion]
    @Published var completionNotificationNotice: String?
    @Published var completionInboxNotice: String?
    let completionNotifier: any TaskCompletionNotifying

    let threadSnapshotService: ThreadSnapshotService
    let compatibilityMonitor: CompatibilityMonitor
    let refreshScheduler: RefreshScheduler
    let accountPopoverActionListener = AccountPopoverActionListener()
    private let userDefaults: UserDefaults
    let codexForegrounder: any CodexForegrounding
    let typingActivityDetector: any TypingActivityDetecting
    let promptLibraryStore: PromptLibraryFileStore
    let accounts: AccountCoordinator
    let compatibilityIssueNotifier: any CompatibilityIssueNotifying
    let synchronizationGate = SynchronizationGate()
    private(set) var dashboardRuntime: (any DashboardRuntime)?
    var refreshGeneration = 0
    var catalogWarning: String?
    var unreadStateWarning: String?
    private var activationObserver: NSObjectProtocol?
    private var codexActivationObserver: NSObjectProtocol?
    private var accountStateObserver: AnyCancellable?
    private var taskCompletionObserver = TaskCompletionObserver()
    var didNotifyAboutDetectedUpdate = false

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
        typingActivityDetector: any TypingActivityDetecting = SystemTypingActivityDetector(),
        promptLibraryStore: PromptLibraryFileStore = PromptLibraryFileStore(),
        accountManager: CodexAccountManager = CodexAccountManager(),
        accountUsageProvider: any AccountUsageProviding = AppServerUsageProvider(),
        accountUsageCacheStore: (any UsageCaching)? = nil,
        compatibilityIssueNotifier: any CompatibilityIssueNotifying = NoopCompatibilityIssueNotifier(),
        completionNotifier: any TaskCompletionNotifying = NoopTaskCompletionNotifier(),
        runtimeFactory: (PromptLibraryFileStore) throws -> any DashboardRuntime = {
            try LocalCodexDashboardRuntime(promptLibraryStore: $0)
        }
    ) {
        threadSnapshotService = ThreadSnapshotService(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: unreadThreadIDProvider
        )
        self.userDefaults = userDefaults
        self.codexForegrounder = codexForegrounder
        self.typingActivityDetector = typingActivityDetector
        self.promptLibraryStore = promptLibraryStore
        self.compatibilityIssueNotifier = compatibilityIssueNotifier
        accounts = AccountCoordinator(
            manager: accountManager,
            usageProvider: accountUsageProvider,
            usageCacheStore: accountUsageCacheStore
        )
        self.completionNotifier = completionNotifier
        completionBehavior = userDefaults.string(forKey: Self.completionBehaviorKey)
            .flatMap(TaskCompletionBehavior.init(rawValue:)) ?? .foreground
        completionInbox = userDefaults.data(forKey: Self.completionInboxKey)
            .flatMap { try? JSONDecoder().decode([TaskCompletion].self, from: $0) } ?? []
        refreshScheduler = RefreshScheduler(observeFileChanges: observeFileChanges)
        compatibilityMonitor = CompatibilityMonitor(
            localChecker: compatibilityChecker,
            userDefaults: userDefaults,
            installedVersion: installedCodexVersion
        )
        do {
            dashboardRuntime = try runtimeFactory(promptLibraryStore)
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
        if codexActivationObserver == nil {
            codexActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                      application.bundleIdentifier == CodexConfiguration.bundleIdentifier
                else { return }
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
        if let codexActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(codexActivationObserver)
            self.codexActivationObserver = nil
        }
    }

    func synchronizeDashboard() async {
        guard !isPerformingAction else { return }
        await synchronizationGate.perform { [weak self] in await self?.synchronizeRuntime() }
    }

    func restartCodexAndEnableDashboard() async {
        guard !isPerformingAction, let dashboardRuntime else { return }
        connectionNotice = nil
        do {
            try await loadThreadSnapshot()
        } catch {
            connectionError =
                "Codex was not restarted because active tasks could not be checked. "
                    + error.localizedDescription
            return
        }
        guard !threads.contains(where: { $0.runState == .running }) else {
            connectionNotice = "Finish or cancel active Codex tasks before restarting."
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
        if lastKnownState.dashboardIsMounted {
            updatePublished(\.connectionError, to: nil)
            updatePublished(\.connectionNotice, to: error.localizedDescription)
        } else {
            updatePublished(\.connectionNotice, to: nil)
            updatePublished(\.connectionError, to: error.localizedDescription)
        }
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
        let previousProjectPaths = Self.liveMonitoredProjectPaths(in: threads)
        let updatedProjectPaths = Self.liveMonitoredProjectPaths(in: updatedThreads)
        let newlyMonitoredProjectPaths = updatedProjectPaths.subtracting(previousProjectPaths)
        refreshScheduler.updateProjectPaths(updatedProjectPaths)
        if threads != updatedThreads { threads = updatedThreads }
        if let totalCount, totalThreadCount != totalCount { totalThreadCount = totalCount }
        if let refreshedAt { lastSuccessfulRefresh = refreshedAt }
        if !newlyMonitoredProjectPaths.isEmpty {
            Task { @MainActor [weak self] in
                await self?.updateWorkingTreeStatuses(projectPaths: newlyMonitoredProjectPaths)
            }
        }
    }

    static func liveMonitoredProjectPaths(in threads: [ThreadSummary]) -> Set<String> {
        let prioritizedThreads = threads.sorted { left, right in
            let leftIsPriority = left.runState == .running || left.isUnread
            let rightIsPriority = right.runState == .running || right.isUnread
            if leftIsPriority != rightIsPriority { return leftIsPriority }
            if left.recencyEpochMillis == right.recencyEpochMillis { return left.id < right.id }
            return left.recencyEpochMillis > right.recencyEpochMillis
        }
        var paths: Set<String> = []
        for thread in prioritizedThreads where paths.count < Self.maximumLiveMonitoredProjectCount {
            paths.insert(thread.projectPath)
        }
        return paths
    }

    func recordCompletions(in threads: [ThreadSummary]) -> [TaskCompletion] {
        let completions = taskCompletionObserver.recordSnapshotAndFindCompletions(in: threads)
        guard !completions.isEmpty else { return [] }
        let completedIDs = Set(completions.map(\.id))
        completionInbox = (completions + completionInbox.filter { !completedIDs.contains($0.id) })
            .sorted {
                if $0.completedAt == $1.completedAt { return $0.id > $1.id }
                return $0.completedAt > $1.completedAt
            }
        persistCompletionInbox()
        return completions
    }

    func dismissCompletion(_ id: String) {
        completionInbox.removeAll { $0.id == id }
        persistCompletionInbox()
    }

    func dismissAllCompletions() {
        completionInbox.removeAll()
        persistCompletionInbox()
    }

    func openCompletedTask(_ id: String) async {
        guard !isPerformingAction else { return }
        completionInboxNotice = nil
        guard let dashboardRuntime, !(await dashboardRuntime.rendererTargets()).isEmpty else {
            completionInboxNotice = "Codex is not connected. Use Restart & Enable from the menu bar, then try opening this task again."
            return
        }
        guard !isPerformingAction else { return }
        codexForegrounder.foregroundCodex()
        await dashboardRuntime.openThread(id, keepingDashboardOpen: false)
    }

    func selectCompletionBehavior(_ behavior: TaskCompletionBehavior) async {
        completionBehavior = behavior
        completionNotificationNotice = nil
        if behavior == .notification {
            let notice = await completionNotifier.prepare()
            if completionBehavior == .notification { completionNotificationNotice = notice }
        }
    }

    private func persistCompletionInbox() {
        guard let data = try? JSONEncoder().encode(completionInbox) else { return }
        userDefaults.set(data, forKey: Self.completionInboxKey)
    }

    static let incompatibleContractMessage =
        "The dashboard was not mounted because a required Codex contract is incompatible. Review Compatibility details."

}
