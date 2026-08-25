import XCTest

@testable import CodexDashboard

final class UsageCacheTests: XCTestCase {
    func testRoundTripsNonSensitiveUsageSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("account-usage.json")
        let store = UsageCache(cacheURL: cacheURL)
        let accountID = UUID()
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(
                    usedPercent: 12,
                    resetsAt: Date(timeIntervalSince1970: 2_000)
                ),
                weekly: CodexUsageWindow(
                    usedPercent: 34,
                    resetsAt: Date(timeIntervalSince1970: 3_000)
                ),
                bankedResets: CodexBankedResetSummary(
                    availableCount: 2,
                    nextExpiration: Date(timeIntervalSince1970: 4_000)
                )
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )

        try store.save([accountID: snapshot])

        XCTAssertEqual(try store.load(), [accountID: snapshot])
        let storedText = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(storedText.contains("token"))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions]
                as? Int,
            0o600
        )
    }

    func testMissingCacheLoadsAsEmpty() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingAccountUsageCache-\(UUID().uuidString).json")

        XCTAssertEqual(try UsageCache(cacheURL: cacheURL).load(), [:])
    }
}
