import XCTest

@testable import CodexDashboard

final class AccountUsageFormatterTests: XCTestCase {
    func testUsageLinesKeepRelativeResetTimingButRemoveVerboseAbsoluteDate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let status = CodexAccountUsageStatus.available(CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(
                    usedPercent: 10,
                    resetsAt: now.addingTimeInterval(3 * 60 * 60 + 15 * 60)
                ),
                weekly: nil
            ),
            fetchedAt: now
        ))

        let lines = AccountUsageFormatter.lines(
            for: status,
            now: now,
            staleTimestampPrefix: "Usage may be stale · updated ",
            includesAbsoluteDate: false,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(lines.first, "5-hour: 90% remaining · resets in 3h 15m")
        XCTAssertFalse(lines.joined().contains("2033"))
    }

    func testAccountUsageLinesIncludeLimitsCountdownsAndBankedResets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let usage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(
                usedPercent: 18,
                resetsAt: now.addingTimeInterval(2 * 60 * 60 + 15 * 60)
            ),
            weekly: CodexUsageWindow(
                usedPercent: 42,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 4 * 60 * 60)
            ),
            bankedResets: CodexBankedResetSummary(
                availableCount: 2,
                nextExpiration: now.addingTimeInterval(24 * 60 * 60)
            )
        )

        let lines = AccountUsageFormatter.lines(
            for: .available(CodexAccountUsageSnapshot(usage: usage, fetchedAt: now)),
            now: now,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(lines, [
            "5-hour: 82% remaining · resets in 2h 15m (18 May 2033 at 5:48)",
            "Weekly: 58% remaining · resets in 3d 4h (21 May 2033 at 7:33)",
            "Banked resets: 2 available · next expires in 1d (19 May 2033 at 3:33)",
        ])
    }

    func testStaleAccountUsageIsClearlyMarked() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 25, resetsAt: nil),
                weekly: nil
            ),
            fetchedAt: now
        )

        let lines = AccountUsageFormatter.lines(
            for: .stale(snapshot),
            now: now
        )

        XCTAssertEqual(lines.first, "5-hour: 75% remaining")
        XCTAssertTrue(lines.last?.hasPrefix("Usage may be stale · updated ") == true)
    }

    func testCachedAccountUsageUsesPlainUpdatedTimestamp() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: nil),
                weekly: CodexUsageWindow(usedPercent: 30, resetsAt: nil)
            ),
            fetchedAt: now
        )

        let lines = AccountUsageFormatter.lines(
            for: .stale(snapshot),
            now: now,
            staleTimestampPrefix: "Updated "
        )

        XCTAssertEqual(lines[0], "5-hour: 90% remaining")
        XCTAssertEqual(lines[1], "Weekly: 70% remaining")
        XCTAssertTrue(lines[2].hasPrefix("Updated "))
    }

    func testLoadingAndUnavailableAccountUsageHaveUsefulPlaceholders() {
        XCTAssertEqual(
            AccountUsageFormatter.lines(for: .loading(previous: nil)),
            ["Loading usage details…"]
        )
        XCTAssertEqual(
            AccountUsageFormatter.lines(for: .unavailable),
            ["Usage details unavailable"]
        )
    }

}
