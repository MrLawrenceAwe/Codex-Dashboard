import Combine
import XCTest

@testable import CodexDashboard

struct StubCatalogProvider: ThreadCatalogProviding {
    let catalog: ThreadCatalog

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async throws -> ThreadCatalog {
        catalog
    }
}

struct StubWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    func loadStatuses(
        for projectPaths: Set<String>,
        policy: WorkingTreeStatusRefreshPolicy
    ) async -> [String: WorkingTreeStatus] {
        [:]
    }
}

actor MutableWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    private var status: WorkingTreeStatus
    private var policies: [WorkingTreeStatusRefreshPolicy] = []

    init(status: WorkingTreeStatus) {
        self.status = status
    }

    func loadStatuses(
        for projectPaths: Set<String>,
        policy: WorkingTreeStatusRefreshPolicy
    ) -> [String: WorkingTreeStatus] {
        policies.append(policy)
        return Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, status) })
    }

    func setStatus(_ status: WorkingTreeStatus) {
        self.status = status
    }

    func latestPolicy() -> WorkingTreeStatusRefreshPolicy? { policies.last }
    func requestCount() -> Int { policies.count }
}

struct StubUnreadIDProvider: UnreadThreadIDProviding {
    let unreadThreadIDs: Set<String>

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }
}

struct FailingViewModelUnreadIDProvider: UnreadThreadIDProviding {
    func loadUnreadThreadIDs() async throws -> Set<String> {
        throw UnreadThreadIDError.invalidState(URL(fileURLWithPath: "/tmp/global-state.json"))
    }
}

actor MutableUnreadIDProvider: UnreadThreadIDProviding {
    private var unreadThreadIDs: Set<String> = []

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }

    func setUnreadThreadIDs(_ threadIDs: Set<String>) {
        unreadThreadIDs = threadIDs
    }
}

actor SuspendedCatalogProvider: ThreadCatalogProviding {
    private var continuations: [CheckedContinuation<ThreadCatalog, Never>] = []
    private(set) var requestCount = 0

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async -> ThreadCatalog {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(
            returning: ThreadCatalog(threads: [], totalThreadCount: 0)
        )
    }

    func count() -> Int {
        requestCount
    }
}

actor SequencedCatalogProvider: ThreadCatalogProviding {
    private var catalogs: [ThreadCatalog]
    private(set) var requestCount = 0

    init(catalogs: [ThreadCatalog]) {
        self.catalogs = catalogs
    }

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async -> ThreadCatalog {
        requestCount += 1
        guard catalogs.count > 1 else {
            return catalogs.first ?? ThreadCatalog(threads: [], totalThreadCount: 0)
        }
        return catalogs.removeFirst()
    }
}

@MainActor
final class RecordingCodexForegrounder: CodexForegrounding {
    private(set) var callCount = 0

    func foregroundCodex() {
        callCount += 1
    }
}

struct StubTypingActivityDetector: TypingActivityDetecting {
    var isUserTyping = false
}

struct StubCompatibilityChecker: LocalCompatibilityChecking {
    let checks: [CompatibilityCheck]

    func checkLocalContracts() async -> [CompatibilityCheck] {
        checks
    }
}

struct StubAccountUsageProvider: AccountUsageProviding {
    func usage() async throws -> CodexAccountUsage {
        CodexAccountUsage(fiveHour: nil, weekly: nil)
    }

    func usage(using credential: Data) async throws -> SavedAccountUsageResult {
        SavedAccountUsageResult(
            usage: CodexAccountUsage(fiveHour: nil, weekly: nil),
            credential: credential
        )
    }

    func reset() async {}
}

func testAccountCredential(accountID: String, name: String) -> Data {
    let claims: [String: Any] = [
        "name": name,
        "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
    ]
    let payload = try! JSONSerialization.data(withJSONObject: claims)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return try! JSONSerialization.data(withJSONObject: [
        "tokens": [
            "account_id": accountID,
            "id_token": "header.\(payload).signature",
        ],
    ])
}

actor RecordingAccountUsageProvider: AccountUsageProviding {
    private(set) var requestCount = 0

    func usage() -> CodexAccountUsage {
        requestCount += 1
        return CodexAccountUsage(fiveHour: nil, weekly: nil)
    }

    func usage(using credential: Data) -> SavedAccountUsageResult {
        requestCount += 1
        return SavedAccountUsageResult(
            usage: CodexAccountUsage(fiveHour: nil, weekly: nil),
            credential: credential
        )
    }

    func reset() {}

    func count() -> Int { requestCount }
}

actor SequencedAccountUsageProvider: AccountUsageProviding {
    private var outcomes: [CodexAccountUsage?]

    init(outcomes: [CodexAccountUsage?]) {
        self.outcomes = outcomes
    }

    func usage() async throws -> CodexAccountUsage {
        guard !outcomes.isEmpty, let usage = outcomes.removeFirst() else {
            throw CodexAccountUsageError.unavailable
        }
        return usage
    }

    func usage(using credential: Data) async throws -> SavedAccountUsageResult {
        SavedAccountUsageResult(usage: try await usage(), credential: credential)
    }

    func reset() async {}
}

actor SuspendedAccountUsageProvider: AccountUsageProviding {
    private var continuation: CheckedContinuation<CodexAccountUsage, Never>?
    private(set) var requestCount = 0

    func usage() async -> CodexAccountUsage {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func usage(using credential: Data) async -> SavedAccountUsageResult {
        requestCount += 1
        return SavedAccountUsageResult(
            usage: CodexAccountUsage(fiveHour: nil, weekly: nil),
            credential: credential
        )
    }

    func reset() async {}

    func resume(with usage: CodexAccountUsage) {
        continuation?.resume(returning: usage)
        continuation = nil
    }

    func count() -> Int { requestCount }
}

actor SavedAccountRecordingUsageProvider: AccountUsageProviding {
    private let usageResult: CodexAccountUsage
    private let refreshedCredential: Data?
    private(set) var receivedCredentials: [Data] = []

    init(usage: CodexAccountUsage, refreshedCredential: Data? = nil) {
        usageResult = usage
        self.refreshedCredential = refreshedCredential
    }

    func usage() -> CodexAccountUsage {
        CodexAccountUsage(fiveHour: nil, weekly: nil)
    }

    func usage(using credential: Data) -> SavedAccountUsageResult {
        receivedCredentials.append(credential)
        return SavedAccountUsageResult(
            usage: usageResult,
            credential: refreshedCredential ?? credential
        )
    }

    func reset() {}

    func credentials() -> [Data] { receivedCredentials }
}

final class RecordingUsageCache: UsageCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [UUID: CodexAccountUsageSnapshot] = [:]
    private var writes = 0

    func load() -> [UUID: CodexAccountUsageSnapshot] {
        lock.withLock { snapshots }
    }

    func save(_ snapshots: [UUID: CodexAccountUsageSnapshot]) {
        lock.withLock {
            self.snapshots = snapshots
            writes += 1
        }
    }

    var saveCount: Int { lock.withLock { writes } }
    var savedSnapshots: [UUID: CodexAccountUsageSnapshot] { lock.withLock { snapshots } }
}

actor SequencedCompatibilityChecker: LocalCompatibilityChecking {
    private var results: [[CompatibilityCheck]]

    init(results: [[CompatibilityCheck]]) {
        self.results = results
    }

    func checkLocalContracts() async -> [CompatibilityCheck] {
        guard results.count > 1 else { return results.first ?? [] }
        return results.removeFirst()
    }
}

final class CoordinatorMemoryCredentialVault: AccountCredentialVault, @unchecked Sendable {
    private var values: [UUID: Data] = [:]
    private let lock = NSLock()

    func credential(for accountID: UUID) -> Data? {
        lock.withLock { values[accountID] }
    }

    func credentialWithoutUserInteraction(for accountID: UUID) -> Data? {
        lock.withLock { values[accountID] }
    }

    func store(_ credential: Data, for accountID: UUID) {
        lock.withLock { values[accountID] = credential }
    }

    func storeWithoutUserInteraction(_ credential: Data, for accountID: UUID) {
        lock.withLock { values[accountID] = credential }
    }

    func deleteCredential(for accountID: UUID) {
        _ = lock.withLock { values.removeValue(forKey: accountID) }
    }
}

@MainActor
final class StubDashboardRuntime: DashboardRuntime {
    let codexIsRunning: Bool
    let codexLaunchDate: Date? = nil
    let maintainsDashboard: Bool
    private let compatibilityChecks: [CompatibilityCheck]
    private let synchronizationError: Error?
    private let restartError: Error?
    private let onRestart: (() -> Void)?
    private let accountPopoverActionWaitResult: AccountPopoverActionWaitResult
    private(set) var restartCallCount = 0
    private(set) var synchronizeCallCount = 0
    private(set) var lastSynchronizedSnapshot: DashboardSnapshot?
    private(set) var accountPopoverSynchronizationCount = 0
    private(set) var lastAccountPopoverSnapshot: AccountPopoverSnapshot?
    private(set) var openedThreadIDs: [String] = []

    init(
        codexIsRunning: Bool = false,
        maintainsDashboard: Bool = false,
        compatibilityChecks: [CompatibilityCheck] = [],
        synchronizationError: Error? = nil,
        restartError: Error? = nil,
        accountPopoverActionWaitResult: AccountPopoverActionWaitResult = .unavailable,
        onRestart: (() -> Void)? = nil
    ) {
        self.codexIsRunning = codexIsRunning
        self.maintainsDashboard = maintainsDashboard
        self.compatibilityChecks = compatibilityChecks
        self.synchronizationError = synchronizationError
        self.restartError = restartError
        self.accountPopoverActionWaitResult = accountPopoverActionWaitResult
        self.onRestart = onRestart
    }

    func rendererTargets() async -> [DevToolsTarget] {
        guard maintainsDashboard else { return [] }
        return [DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )]
    }
    func preferNativePromptLibraryOnNextSynchronization() {}
    func prepareForRestart() {}
    func restartCodex() async throws -> [DevToolsTarget] {
        restartCallCount += 1
        onRestart?()
        if let restartError { throw restartError }
        return []
    }
    func synchronizeDashboard(
        with snapshot: DashboardSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws {
        synchronizeCallCount += 1
        lastSynchronizedSnapshot = snapshot
        if let synchronizationError { throw synchronizationError }
    }
    func disableIntegration() async throws -> DashboardDisableOutcome { .codexClosed }
    func openTaskDashboard() async {}
    func openThread(_ threadID: String) async { openedThreadIDs.append(threadID) }
    func waitForAccountPopoverAction() async -> AccountPopoverActionWaitResult {
        accountPopoverActionWaitResult
    }
    func synchronizeAccountPopover(_ snapshot: AccountPopoverSnapshot) async {
        accountPopoverSynchronizationCount += 1
        lastAccountPopoverSnapshot = snapshot
    }
    func rendererCompatibilityChecks() async -> [CompatibilityCheck] { compatibilityChecks }
}

@MainActor
extension XCTestCase {
    func makeAppCoordinator(
        catalogProvider: any ThreadCatalogProviding = StubCatalogProvider(
            catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
        ),
        workingTreeStatusProvider: any WorkingTreeStatusProviding = StubWorkingTreeStatusProvider(),
        unreadThreadIDProvider: any UnreadThreadIDProviding = StubUnreadIDProvider(
            unreadThreadIDs: []
        ),
        compatibilityChecker: any LocalCompatibilityChecking = StubCompatibilityChecker(checks: []),
        userDefaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
        observeFileChanges: Bool = true,
        installedCodexVersion: @escaping () -> String? = { nil },
        codexForegrounder: any CodexForegrounding = RecordingCodexForegrounder(),
        typingActivityDetector: any TypingActivityDetecting = StubTypingActivityDetector(),
        promptLibraryStore: PromptLibraryFileStore = PromptLibraryFileStore(),
        accountManager: CodexAccountManager? = nil,
        accountUsageProvider: any AccountUsageProviding = StubAccountUsageProvider(),
        accountUsageCacheStore: (any UsageCaching)? = nil,
        compatibilityIssueNotifier: any CompatibilityIssueNotifying = RecordingCompatibilityIssueNotifier(),
        desktopUsageNotifier: any DesktopUsageNotifying = NoopDesktopUsageNotifier(),
        phoneUsageNotifier: any PhoneUsageNotifying = NoopPhoneUsageNotifier(),
        runtimeFactory: (PromptLibraryFileStore) throws -> any DashboardRuntime = { _ in StubDashboardRuntime() }
    ) -> AppCoordinator {
        let accountDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorAccounts-\(UUID().uuidString)")
        let isolatedAccountManager = accountManager ?? CodexAccountManager(
            metadataURL: accountDirectory.appendingPathComponent("accounts.json"),
            authenticationURL: accountDirectory.appendingPathComponent("auth.json"),
            vault: CoordinatorMemoryCredentialVault()
        )
        let coordinator = AppCoordinator(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: workingTreeStatusProvider,
            unreadThreadIDProvider: unreadThreadIDProvider,
            compatibilityChecker: compatibilityChecker,
            userDefaults: userDefaults,
            observeFileChanges: observeFileChanges,
            installedCodexVersion: installedCodexVersion,
            codexForegrounder: codexForegrounder,
            typingActivityDetector: typingActivityDetector,
            promptLibraryStore: promptLibraryStore,
            accountManager: isolatedAccountManager,
            accountUsageProvider: accountUsageProvider,
            accountUsageCacheStore: accountUsageCacheStore,
            compatibilityIssueNotifier: compatibilityIssueNotifier,
            desktopUsageNotifier: desktopUsageNotifier,
            phoneUsageNotifier: phoneUsageNotifier,
            runtimeFactory: runtimeFactory
        )
        addTeardownBlock {
            await MainActor.run { coordinator.stopMonitoring() }
            try? FileManager.default.removeItem(at: accountDirectory)
        }
        return coordinator
    }
}

@MainActor
final class RecordingCompatibilityIssueNotifier: CompatibilityIssueNotifying {
    private(set) var reports: [CompatibilityReport] = []

    func notify(report: CompatibilityReport) async {
        reports.append(report)
    }
}
