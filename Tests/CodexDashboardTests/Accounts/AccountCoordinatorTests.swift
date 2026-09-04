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
final class AccountCoordinatorTests: XCTestCase {
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
}
