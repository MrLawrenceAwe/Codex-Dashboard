import XCTest

@testable import CodexDashboard

@MainActor
final class NotificationUsageRefresherTests: XCTestCase {
    func testReusesLatestObservationThenExpiresAndRejectsFailedRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticationURL = directory.appendingPathComponent("auth.json")
        try testAccountCredential(accountID: "notification-account", name: "Account")
            .write(to: authenticationURL)
        let manager = CodexAccountManager(
            metadataURL: directory.appendingPathComponent("accounts.json"),
            authenticationURL: authenticationURL,
            vault: CoordinatorMemoryCredentialVault()
        )
        let account = try manager.saveCurrentAccount()
        let observations = [20, 40, 60].map {
            CodexAccountUsage(fiveHour: CodexUsageWindow(usedPercent: $0, resetsAt: nil), weekly: nil)
        }
        let accounts = AccountCoordinator(
            manager: manager,
            usageProvider: SequencedAccountUsageProvider(outcomes: observations + [nil])
        )
        var currentDate = Date.now
        let refresher = NotificationUsageRefresher(accounts: accounts, now: { currentDate })
        let first = await refresher.refresh(account.id, codexIsRunning: true)
        let reused = await refresher.refresh(account.id, codexIsRunning: true)
        XCTAssertEqual(first?.usage, observations[0])
        XCTAssertEqual(reused, first)

        await accounts.refreshActiveUsage(codexIsRunning: true)
        let newer = await refresher.refresh(account.id, codexIsRunning: true)
        XCTAssertEqual(newer?.usage, observations[1])

        currentDate.addTimeInterval(61)
        let expired = await refresher.refresh(account.id, codexIsRunning: true)
        XCTAssertEqual(expired?.usage, observations[2])

        currentDate.addTimeInterval(61)
        let failed = await refresher.refresh(account.id, codexIsRunning: true)
        XCTAssertNil(failed, "A failed refresh must not return an expired observation as fresh usage.")
    }
}
