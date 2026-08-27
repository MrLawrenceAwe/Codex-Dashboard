import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    func testActiveUsageRefreshPublishesUpdatedAccountPopover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorUsagePublicationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try testAccountCredential(accountID: "account-lawrence", name: "Lawrence")
            .write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("support/accounts.json"),
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        _ = try accountManager.saveCurrentAccount()
        let usage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: nil),
            weekly: CodexUsageWindow(usedPercent: 40, resetsAt: nil)
        )
        let runtime = StubDashboardRuntime(
            codexIsRunning: true,
            maintainsDashboard: true
        )
        let coordinator = makeAppCoordinator(
            accountManager: accountManager,
            accountUsageProvider: SequencedAccountUsageProvider(outcomes: [usage]),
            runtimeFactory: { runtime }
        )

        await coordinator.refreshAccountUsage()

        XCTAssertEqual(runtime.accountPopoverSynchronizationCount, 1)
        let item = try XCTUnwrap(runtime.lastAccountPopoverSnapshot?.accounts.first)
        XCTAssertTrue(item.usageLines.contains { $0.contains("80% remaining") })
        XCTAssertTrue(item.usageLines.contains { $0.contains("60% remaining") })
    }

    func testUsageFailureMarksPreviousUnsavedAccountUsageStale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let usage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: nil),
            weekly: CodexUsageWindow(usedPercent: 40, resetsAt: nil)
        )
        let provider = SequencedAccountUsageProvider(outcomes: [usage, nil])
        let coordinator = makeAppCoordinator(
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
        guard case .available = coordinator.accounts.activeUsageStatus else {
            return XCTFail("Expected available usage")
        }
        await coordinator.refreshAccountUsage()
        guard case .stale(let snapshot) = coordinator.accounts.activeUsageStatus else {
            return XCTFail("Expected stale usage")
        }
        XCTAssertEqual(snapshot.usage, usage)
    }

    func testConcurrentUsageRefreshesAreCoalesced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorUsageCoalescingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SuspendedAccountUsageProvider()
        let coordinator = makeAppCoordinator(
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
        let second = Task { @MainActor in await coordinator.refreshAccountUsage() }
        let requestCount = await provider.count()
        XCTAssertEqual(requestCount, 1)
        await provider.resume(with: CodexAccountUsage(fiveHour: nil, weekly: nil))
        await first.value
        await second.value
    }

    func testUsageRefreshIsSkippedWhileCodexIsClosed() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorClosedUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SuspendedAccountUsageProvider()
        let coordinator = makeAppCoordinator(
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
        XCTAssertEqual(coordinator.accounts.activeUsageStatus, .unavailable)
    }

    func testRestoresCachedUsageForActiveAccountAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorUsageRestoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try testAccountCredential(accountID: "account-lawrence", name: "Lawrence")
            .write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("support/accounts.json"),
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let account = try accountManager.saveCurrentAccount()
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: nil),
                weekly: CodexUsageWindow(usedPercent: 40, resetsAt: nil)
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
        try accountManager.usageCacheStore.save([account.id: snapshot])

        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: accountManager,
            accountUsageProvider: StubAccountUsageProvider(),
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: false) }
        )

        XCTAssertEqual(coordinator.accounts.usageByAccountID[account.id], snapshot)
        XCTAssertEqual(coordinator.accounts.activeUsageStatus, .stale(snapshot))
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
        try testAccountCredential(accountID: "account-lawrence", name: "Lawrence")
            .write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: metadataURL,
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        _ = try accountManager.saveCurrentAccount()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
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
            coordinator.accounts.statusMessage,
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
        let lawrenceCredential = testAccountCredential(
            accountID: "account-lawrence", name: "Lawrence"
        )
        try lawrenceCredential.write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: metadataURL,
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let lawrence = try accountManager.saveCurrentAccount()
        _ = try accountManager.beginAddingAccount()
        let mumCredential = testAccountCredential(accountID: "account-mum", name: "Mum")
        try mumCredential.write(to: authenticationURL)
        _ = try accountManager.saveCurrentAccount()
        let runtime = StubDashboardRuntime(synchronizationError: AccountTestError.mountFailed)
        let coordinator = makeAppCoordinator(
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
        XCTAssertEqual(try Data(contentsOf: authenticationURL), lawrenceCredential)
        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertEqual(runtime.synchronizeCallCount, 1)
        XCTAssertEqual(coordinator.connectionState, .rendererAvailable)
        XCTAssertEqual(
            coordinator.accounts.statusMessage,
            "Switched to Lawrence. The dashboard will reconnect when Codex is ready."
        )
    }

    func testAccountSwitchRefreshesTaskStateBeforeRestartingCodex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorFreshTaskCheckTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let firstCredential = testAccountCredential(accountID: "account-first", name: "First")
        let secondCredential = testAccountCredential(accountID: "account-second", name: "Second")
        try firstCredential.write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("support/accounts.json"),
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let first = try accountManager.saveCurrentAccount()
        _ = try accountManager.beginAddingAccount()
        try secondCredential.write(to: authenticationURL)
        let second = try accountManager.saveCurrentAccount()
        let catalogProvider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(threads: [.fixture(runState: .idle)], totalThreadCount: 1),
            ThreadCatalog(threads: [.fixture(runState: .running)], totalThreadCount: 1),
        ])
        let runtime = StubDashboardRuntime(codexIsRunning: true)
        let coordinator = makeAppCoordinator(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: accountManager,
            accountUsageProvider: StubAccountUsageProvider(),
            runtimeFactory: { runtime }
        )
        await coordinator.synchronizeDashboard()

        await coordinator.switchAccount(to: first.id)

        XCTAssertEqual(try accountManager.document().activeAccountID, second.id)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), secondCredential)
        XCTAssertEqual(runtime.restartCallCount, 0)
        XCTAssertEqual(
            coordinator.accounts.statusMessage,
            CodexAccountError.activeTasks.localizedDescription
        )
    }

    func testBlockedAccountSwitchRestoresUsageStatusAfterCancellingRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorBlockedSwitchUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let firstCredential = testAccountCredential(accountID: "account-first", name: "First")
        let secondCredential = testAccountCredential(accountID: "account-second", name: "Second")
        try firstCredential.write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("support/accounts.json"),
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let first = try accountManager.saveCurrentAccount()
        _ = try accountManager.beginAddingAccount()
        try secondCredential.write(to: authenticationURL)
        _ = try accountManager.saveCurrentAccount()
        let usageProvider = SuspendedAccountUsageProvider()
        let coordinator = makeAppCoordinator(
            catalogProvider: SequencedCatalogProvider(catalogs: [
                ThreadCatalog(threads: [.fixture(runState: .idle)], totalThreadCount: 1),
                ThreadCatalog(threads: [.fixture(runState: .running)], totalThreadCount: 1),
            ]),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: accountManager,
            accountUsageProvider: usageProvider,
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: true) }
        )
        await coordinator.synchronizeDashboard()

        let refresh = Task { @MainActor in await coordinator.refreshAccountUsage() }
        try await waitUntil { await usageProvider.count() == 1 }
        await coordinator.switchAccount(to: first.id)
        await usageProvider.resume(with: CodexAccountUsage(fiveHour: nil, weekly: nil))
        await refresh.value

        XCTAssertEqual(coordinator.accounts.activeUsageStatus, .unavailable)
        XCTAssertEqual(
            coordinator.accounts.statusMessage,
            CodexAccountError.activeTasks.localizedDescription
        )
    }

    func testFailedRollbackIsReportedAndDoesNotAttemptAnotherRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorRollbackTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        let metadataURL = directory.appendingPathComponent("support/accounts.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let firstCredential = testAccountCredential(accountID: "account-first", name: "First")
        try firstCredential.write(to: authenticationURL)
        let accountManager = CodexAccountManager(
            metadataURL: metadataURL,
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let first = try accountManager.saveCurrentAccount()
        _ = try accountManager.beginAddingAccount()
        let secondCredential = testAccountCredential(accountID: "account-second", name: "Second")
        try secondCredential.write(to: authenticationURL)
        _ = try accountManager.saveCurrentAccount()
        let runtime = StubDashboardRuntime(
            restartError: AccountTestError.mountFailed,
            onRestart: {
                try? FileManager.default.removeItem(at: metadataURL)
                try? FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
            }
        )
        let coordinator = makeAppCoordinator(
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

        await coordinator.switchAccount(to: first.id)

        XCTAssertEqual(runtime.restartCallCount, 1)
        XCTAssertTrue(
            coordinator.accounts.statusMessage?.contains("could not be rolled back") == true
        )
        XCTAssertEqual(
            try Data(contentsOf: authenticationURL),
            firstCredential
        )
    }

    func testAccountUsagePollingScheduleRefreshesEveryThirtySeconds() {
        XCTAssertEqual(RefreshScheduler.Schedule.accountUsage, .seconds(30))
    }

    func testInactiveAccountUsagePollingScheduleRefreshesEveryFiveMinutes() {
        XCTAssertEqual(RefreshScheduler.Schedule.inactiveAccountUsage, .seconds(5 * 60))
    }

    func testInactiveAccountUsageRefreshDoesNotSwitchActiveAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorInactiveUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let firstCredential = testAccountCredential(accountID: "account-first", name: "First")
        let secondCredential = testAccountCredential(accountID: "account-second", name: "Second")
        let refreshedFirstCredential = testAccountCredential(
            accountID: "account-first", name: "First Refreshed"
        )
        try firstCredential.write(to: authenticationURL)
        let vault = CoordinatorMemoryCredentialVault()
        let accountManager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("support/accounts.json"),
            authenticationURL: authenticationURL,
            vault: vault
        )
        let first = try accountManager.saveCurrentAccount()
        _ = try accountManager.beginAddingAccount()
        try secondCredential.write(to: authenticationURL)
        let second = try accountManager.saveCurrentAccount()
        let usage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 22, resetsAt: nil),
            weekly: CodexUsageWindow(usedPercent: 44, resetsAt: nil)
        )
        let provider = SavedAccountRecordingUsageProvider(
            usage: usage,
            refreshedCredential: refreshedFirstCredential
        )
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [], totalThreadCount: 0)
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            accountManager: accountManager,
            accountUsageProvider: provider,
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: true) }
        )

        _ = await coordinator.refreshSavedAccountUsage(first.id)
        let receivedCredentials = await provider.credentials()

        XCTAssertEqual(coordinator.accounts.activeAccountID, second.id)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), secondCredential)
        XCTAssertEqual(receivedCredentials, [firstCredential])
        XCTAssertEqual(vault.credential(for: first.id), refreshedFirstCredential)
        XCTAssertEqual(coordinator.accounts.usageByAccountID[first.id]?.usage, usage)
        XCTAssertNil(coordinator.accounts.usageErrorsByAccountID[first.id])
    }

    func testInactiveAccountUsageBatchPersistsCacheOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoordinatorInactiveUsageBatchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let credentials = [
            testAccountCredential(accountID: "account-first", name: "First"),
            testAccountCredential(accountID: "account-second", name: "Second"),
            testAccountCredential(accountID: "account-active", name: "Active"),
        ]
        let accountManager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("support/accounts.json"),
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        var accounts: [SavedAccount] = []
        for (index, credential) in credentials.enumerated() {
            if index > 0 { _ = try accountManager.beginAddingAccount() }
            try credential.write(to: authenticationURL)
            accounts.append(try accountManager.saveCurrentAccount())
        }
        let usage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 22, resetsAt: nil),
            weekly: CodexUsageWindow(usedPercent: 44, resetsAt: nil)
        )
        let cache = RecordingUsageCache()
        let coordinator = makeAppCoordinator(
            accountManager: accountManager,
            accountUsageProvider: SavedAccountRecordingUsageProvider(
                usage: usage,
                refreshedCredential: credentials[0]
            ),
            accountUsageCacheStore: cache,
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: true) }
        )

        await coordinator.refreshInactiveAccountUsage()

        XCTAssertEqual(cache.saveCount, 1)
        XCTAssertEqual(Set(cache.savedSnapshots.keys), Set(accounts.dropLast().map(\.id)))
        XCTAssertTrue(cache.savedSnapshots.values.allSatisfy { $0.usage == usage })
    }

}
