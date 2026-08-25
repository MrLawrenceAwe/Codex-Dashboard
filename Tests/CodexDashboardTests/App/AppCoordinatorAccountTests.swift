import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    func testUsageFailureMarksPreviousUnsavedAccountUsageStale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let usage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: nil),
            weekly: CodexUsageWindow(usedPercent: 40, resetsAt: nil)
        )
        let provider = SequencedAccountUsageProvider(outcomes: [usage, nil])
        let coordinator = AppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: CodexAccountManager(
                metadataURL: directory.appendingPathComponent("accounts.json"),
                authenticationURL: directory.appendingPathComponent("auth.json"),
                vault: CoordinatorMemoryCredentialVault()
            ),
            accountUsageProvider: provider,
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: true) }
        )

        await coordinator.refreshAccountUsage()
        guard case .available = coordinator.activeAccountUsageStatus else {
            return XCTFail("Expected available usage")
        }
        await coordinator.refreshAccountUsage()
        guard case .stale(let snapshot) = coordinator.activeAccountUsageStatus else {
            return XCTFail("Expected stale usage")
        }
        XCTAssertEqual(snapshot.usage, usage)
    }

    func testConcurrentUsageRefreshesAreCoalesced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorUsageCoalescingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SuspendedAccountUsageProvider()
        let coordinator = AppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: CodexAccountManager(
                metadataURL: directory.appendingPathComponent("accounts.json"),
                authenticationURL: directory.appendingPathComponent("auth.json"),
                vault: CoordinatorMemoryCredentialVault()
            ),
            accountUsageProvider: provider,
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: true) }
        )

        let first = Task { @MainActor in await coordinator.refreshAccountUsage() }
        try await waitUntil { await provider.count() == 1 }
        await coordinator.refreshAccountUsage()
        let requestCount = await provider.count()
        XCTAssertEqual(requestCount, 1)
        await provider.resume(with: CodexAccountUsage(fiveHour: nil, weekly: nil))
        await first.value
    }

    func testUsageRefreshIsSkippedWhileCodexIsClosed() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorClosedUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SuspendedAccountUsageProvider()
        let coordinator = AppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: CodexAccountManager(
                metadataURL: directory.appendingPathComponent("accounts.json"),
                authenticationURL: directory.appendingPathComponent("auth.json"),
                vault: CoordinatorMemoryCredentialVault()
            ),
            accountUsageProvider: provider,
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: false) }
        )

        await coordinator.refreshAccountUsage()

        let requestCount = await provider.count()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(coordinator.activeAccountUsageStatus, .unavailable)
    }

    func testRestoresCachedUsageForActiveAccountAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorUsageRestoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"account":"lawrence"}"#.utf8).write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("support/accounts.json"),
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let account = try accountManager.saveCurrentAccount(named: "Lawrence")
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: nil),
                weekly: CodexUsageWindow(usedPercent: 40, resetsAt: nil)
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
        try accountManager.usageCacheStore.save([account.id: snapshot])

        let coordinator = AppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: accountManager,
            accountUsageProvider: StubAccountUsageProvider(),
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: false) }
        )

        XCTAssertEqual(coordinator.usageByAccountID[account.id], snapshot)
        XCTAssertEqual(coordinator.activeAccountUsageStatus, .stale(snapshot))
    }

    func testAddingAccountKeepsSignedOutStateWithoutTryingToMountDashboard() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorAccountTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        let metadataURL = directory.appendingPathComponent("support/accounts.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"account":"lawrence"}"#.utf8).write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: metadataURL,
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        _ = try accountManager.saveCurrentAccount(named: "Lawrence")
        let runtime = StubDashboardRuntime()
        let coordinator = AppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            accountManager: accountManager,
            accountUsageProvider: StubAccountUsageProvider(),
            runtimeFactory: { runtime }
        )

        await coordinator.beginAddingAccount()

        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertEqual(runtime.synchronizeCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authenticationURL.path))
        XCTAssertNil(try accountManager.document().activeAccountID)
        XCTAssertEqual(coordinator.connectionState, .rendererAvailable)
        XCTAssertEqual(
            coordinator.accountStatusMessage,
            "Sign in to the other account, then save it from Accounts."
        )
    }

    func testSuccessfulCredentialSwitchIsNotRolledBackWhenDashboardMountFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorSwitchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        let metadataURL = directory.appendingPathComponent("support/accounts.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"account":"lawrence"}"#.utf8).write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: metadataURL,
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let lawrence = try accountManager.saveCurrentAccount(named: "Lawrence")
        _ = try accountManager.beginAddingAccount()
        try Data(#"{"account":"mum"}"#.utf8).write(to: authenticationURL)
        _ = try accountManager.saveCurrentAccount(named: "Mum")
        let runtime = StubDashboardRuntime(synchronizationError: AccountTestError.mountFailed)
        let coordinator = AppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            accountManager: accountManager,
            accountUsageProvider: StubAccountUsageProvider(),
            runtimeFactory: { runtime }
        )

        await coordinator.switchAccount(to: lawrence.id)

        XCTAssertEqual(try accountManager.document().activeAccountID, lawrence.id)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), Data(#"{"account":"lawrence"}"#.utf8))
        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertEqual(runtime.synchronizeCallCount, 1)
        XCTAssertEqual(coordinator.connectionState, .rendererAvailable)
        XCTAssertEqual(
            coordinator.accountStatusMessage,
            "Switched to Lawrence. The dashboard will reconnect when Codex is ready."
        )
    }

    func testAccountUsagePollingScheduleRefreshesEveryThirtySeconds() {
        XCTAssertEqual(PollingController.Schedule.accountUsage, .seconds(30))
    }

}
