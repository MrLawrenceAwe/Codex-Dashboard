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
    func loadStatuses(for projectPaths: Set<String>) async -> [String: WorkingTreeStatus] {
        [:]
    }
}

actor MutableWorkingTreeStatusProvider: WorkingTreeStatusProviding {
    private var status: WorkingTreeStatus

    init(status: WorkingTreeStatus) {
        self.status = status
    }

    func loadStatuses(for projectPaths: Set<String>) -> [String: WorkingTreeStatus] {
        Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, status) })
    }

    func setStatus(_ status: WorkingTreeStatus) {
        self.status = status
    }
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

    init(catalogs: [ThreadCatalog]) {
        self.catalogs = catalogs
    }

    func loadCatalog(codexLaunchDate: Date?, requiredThreadIDs: Set<String>) async -> ThreadCatalog {
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

    func reset() async {}
}

actor RecordingAccountUsageProvider: AccountUsageProviding {
    private(set) var requestCount = 0

    func usage() -> CodexAccountUsage {
        requestCount += 1
        return CodexAccountUsage(fiveHour: nil, weekly: nil)
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

    func reset() async {}
}

actor SuspendedAccountUsageProvider: AccountUsageProviding {
    private var continuation: CheckedContinuation<CodexAccountUsage, Never>?
    private(set) var requestCount = 0

    func usage() async -> CodexAccountUsage {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func reset() async {}

    func resume(with usage: CodexAccountUsage) {
        continuation?.resume(returning: usage)
        continuation = nil
    }

    func count() -> Int { requestCount }
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

    func store(_ credential: Data, for accountID: UUID) {
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
    let maintainsDashboard = false
    private let compatibilityChecks: [CompatibilityCheck]
    private let synchronizationError: Error?
    private let restartError: Error?
    private let onRestart: (() -> Void)?
    private(set) var restartCallCount = 0
    private(set) var synchronizeCallCount = 0
    private(set) var openedThreadIDs: [String] = []

    init(
        codexIsRunning: Bool = false,
        compatibilityChecks: [CompatibilityCheck] = [],
        synchronizationError: Error? = nil,
        restartError: Error? = nil,
        onRestart: (() -> Void)? = nil
    ) {
        self.codexIsRunning = codexIsRunning
        self.compatibilityChecks = compatibilityChecks
        self.synchronizationError = synchronizationError
        self.restartError = restartError
        self.onRestart = onRestart
    }

    func rendererTargets() async -> [DevToolsTarget] { [] }
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
        if let synchronizationError { throw synchronizationError }
    }
    func disableThreadDashboard() async throws -> DashboardDisableOutcome { .codexClosed }
    func openThreadDashboard() async {}
    func openThread(_ threadID: String) async { openedThreadIDs.append(threadID) }
    func rendererCompatibilityChecks() async -> [CompatibilityCheck] { compatibilityChecks }
}

@MainActor
final class AppCoordinatorTests: XCTestCase {
    enum AccountTestError: Error { case mountFailed }

    func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let conditionWasMet = await condition()
        XCTAssertTrue(conditionWasMet)
    }
}
