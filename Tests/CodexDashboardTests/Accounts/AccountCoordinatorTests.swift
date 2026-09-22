import XCTest
@testable import CodexDashboard

private actor CachedAccountUsageProvider: AccountUsageProviding {
    private var current: CodexAccountUsage
    private var cached: CodexAccountUsage?

    init(_ current: CodexAccountUsage) { self.current = current }
    func changeAccountUsage(to usage: CodexAccountUsage) { current = usage }
    func usage() -> CodexAccountUsage {
        if let cached { return cached }
        cached = current
        return current
    }
    func usage(using credential: Data) -> SavedAccountUsageResult {
        SavedAccountUsageResult(usage: current, credential: credential)
    }
    func reset() { cached = nil }
}

@MainActor
private final class AccountChangingUsageProvider: AccountUsageProviding {
    var onFetch: (() throws -> Void)?
    private(set) var requestCount = 0

    func usage() async throws -> CodexAccountUsage {
        CodexAccountUsage(fiveHour: nil, weekly: nil)
    }

    func usage(using credential: Data) async throws -> SavedAccountUsageResult {
        requestCount += 1
        try onFetch?()
        return SavedAccountUsageResult(usage: try await usage(), credential: credential)
    }

    func reset() async {}
}

private struct InteractiveOnlyCredentialVault: AccountCredentialVault {
    let storage = CoordinatorMemoryCredentialVault()

    func credential(for accountID: UUID) throws -> Data? { storage.credential(for: accountID) }
    func store(_ credential: Data, for accountID: UUID) throws { storage.store(credential, for: accountID) }
    func deleteCredential(for accountID: UUID) throws { storage.deleteCredential(for: accountID) }
    func credentialWithoutUserInteraction(for accountID: UUID) throws -> Data? {
        throw CodexAccountError.keychainAuthorizationRequired
    }
    func storeWithoutUserInteraction(_ credential: Data, for accountID: UUID) throws {
        throw CodexAccountError.keychainAuthorizationRequired
    }
}

private struct ExpiredAccountUsageProvider: AccountUsageProviding {
    func usage() async throws -> CodexAccountUsage {
        CodexAccountUsage(fiveHour: nil, weekly: nil)
    }

    func usage(using credential: Data) async throws -> SavedAccountUsageResult {
        throw CodexAccountUsageError.authenticationExpired
    }

    func reset() async {}
}

@MainActor
final class AccountCoordinatorTests: XCTestCase {
    func testExpiredInactiveAccountRequiresSignInInsteadOfCredentialSwitch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let vault = CoordinatorMemoryCredentialVault()
        let manager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("accounts.json"),
            authenticationURL: auth,
            vault: vault
        )
        try testAccountCredential(accountID: "expired", name: "Expired").write(to: auth)
        let expired = try manager.saveCurrentAccount()
        try testAccountCredential(accountID: "active", name: "Active").write(to: auth)
        _ = try manager.saveCurrentAccount()
        let coordinator = AccountCoordinator(
            manager: manager,
            usageProvider: ExpiredAccountUsageProvider()
        )

        _ = await coordinator.refreshInactiveAccountUsage(
            expired.id,
            interactionAllowed: true
        )

        let item = try XCTUnwrap(
            coordinator.popoverSnapshot(isBusy: false).accounts.first { $0.id == expired.id }
        )
        XCTAssertTrue(item.requiresSignIn)
        XCTAssertEqual(
            item.errorMessage,
            "Sign-in expired. Select Sign in to authenticate this account again."
        )

        var refreshedCredentialObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: testAccountCredential(accountID: "expired", name: "Expired")
            ) as? [String: Any]
        )
        refreshedCredentialObject["last_refresh"] = "fresh"
        let refreshedCredential = try JSONSerialization.data(
            withJSONObject: refreshedCredentialObject
        )
        try refreshedCredential.write(to: auth)
        coordinator.refreshState()

        XCTAssertTrue(coordinator.synchronizeActiveCredentialAfterFileChange())
        let refreshedItem = try XCTUnwrap(
            coordinator.popoverSnapshot(isBusy: false).accounts.first { $0.id == expired.id }
        )
        XCTAssertFalse(refreshedItem.requiresSignIn)
        XCTAssertNil(refreshedItem.errorMessage)
        XCTAssertEqual(vault.credential(for: expired.id), refreshedCredential)
        XCTAssertEqual(
            coordinator.statusMessage,
            "Signed in as Expired. Saved the refreshed credential securely in Keychain."
        )
    }

    func testInteractiveBatchRefreshCanReadProtectedAccountsAndPersistsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let manager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("accounts.json"),
            authenticationURL: auth,
            vault: InteractiveOnlyCredentialVault()
        )
        var saved: [SavedAccount] = []
        for name in ["First", "Second", "Active"] {
            try testAccountCredential(accountID: name, name: name).write(to: auth)
            saved.append(try manager.saveCurrentAccount())
        }
        let cache = RecordingUsageCache()
        let coordinator = AccountCoordinator(
            manager: manager, usageProvider: StubAccountUsageProvider(), usageCacheStore: cache
        )
        await coordinator.refreshInactiveUsage()
        XCTAssertTrue(coordinator.usageByAccountID.isEmpty)
        XCTAssertNil(coordinator.statusMessage)
        let previousWrites = cache.saveCount

        await coordinator.refreshInactiveUsage(interactionAllowed: true)

        XCTAssertEqual(cache.saveCount, previousWrites + 1)
        XCTAssertEqual(Set(cache.savedSnapshots.keys), Set(saved.dropLast().map(\.id)))
        XCTAssertEqual(coordinator.activeAccountID, saved.last?.id)
        XCTAssertTrue(coordinator.refreshingUsageAccountIDs.isEmpty)
    }

    func testBatchStopsWhenAccountIdentityChangesDuringRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let manager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("accounts.json"),
            authenticationURL: auth,
            vault: CoordinatorMemoryCredentialVault()
        )
        for name in ["First", "Second", "Active"] {
            try testAccountCredential(accountID: name, name: name).write(to: auth)
            _ = try manager.saveCurrentAccount()
        }
        let provider = AccountChangingUsageProvider()
        let coordinator = AccountCoordinator(manager: manager, usageProvider: provider)
        provider.onFetch = { [weak coordinator] in
            try testAccountCredential(accountID: "New", name: "New").write(to: auth)
            coordinator?.refreshState()
        }

        await coordinator.refreshInactiveUsage(interactionAllowed: true)

        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertTrue(coordinator.usageByAccountID.isEmpty)
        XCTAssertTrue(coordinator.refreshingUsageAccountIDs.isEmpty)
    }

    func testExternalAccountChangeDoesNotKeepPreviousAccountsUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let manager = CodexAccountManager(metadataURL: directory.appendingPathComponent("accounts.json"), authenticationURL: auth, vault: CoordinatorMemoryCredentialVault())
        let credentialA = testAccountCredential(accountID: "A", name: "A")
        let credentialB = testAccountCredential(accountID: "B", name: "B")
        try credentialA.write(to: auth)
        _ = try manager.saveCurrentAccount()
        try credentialB.write(to: auth)
        let accountB = try manager.saveCurrentAccount()
        try credentialA.write(to: auth)
        let usageA = CodexAccountUsage(fiveHour: CodexUsageWindow(usedPercent: 80, resetsAt: nil), weekly: nil)
        let provider = CachedAccountUsageProvider(usageA)
        let coordinator = AccountCoordinator(manager: manager, usageProvider: provider)
        await coordinator.refreshActiveUsage(codexIsRunning: true)
        let usageB = CodexAccountUsage(fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: nil), weekly: nil)
        await provider.changeAccountUsage(to: usageB)
        try credentialB.write(to: auth)
        coordinator.refreshState()
        XCTAssertEqual(coordinator.activeAccountID, accountB.id)
        XCTAssertNil(coordinator.activeUsageStatus.snapshot, "Account B has never had usage fetched; must not show A's usage")
        await coordinator.refreshActiveUsage(codexIsRunning: true)
        XCTAssertEqual(coordinator.activeUsageStatus.snapshot?.usage, usageB)
        XCTAssertEqual(coordinator.usageByAccountID[accountB.id]?.usage, usageB)

        // Also reconcile when refresh runs before the filesystem notification arrives.
        await provider.changeAccountUsage(to: usageA)
        try credentialA.write(to: auth)
        await coordinator.refreshActiveUsage(codexIsRunning: true)
        XCTAssertEqual(coordinator.activeUsageStatus.snapshot?.usage, usageA)
    }

    func testForgettingActiveAccountDoesNotAutomaticallySaveItAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let manager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("accounts.json"),
            authenticationURL: auth,
            vault: CoordinatorMemoryCredentialVault()
        )
        try testAccountCredential(accountID: "active", name: "Active").write(to: auth)
        let account = try manager.saveCurrentAccount()
        let coordinator = AccountCoordinator(manager: manager, usageProvider: StubAccountUsageProvider())

        coordinator.deleteAccount(account.id)
        XCTAssertFalse(coordinator.synchronizeActiveCredentialAfterFileChange())
        XCTAssertTrue(try manager.loadDocument().accounts.isEmpty)
        XCTAssertNil(coordinator.activeAccountID)

        XCTAssertTrue(coordinator.saveCurrentAccount())
        XCTAssertEqual(try manager.loadDocument().accounts.count, 1)
    }
}
