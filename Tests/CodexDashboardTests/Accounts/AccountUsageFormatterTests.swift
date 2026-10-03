import XCTest

@testable import CodexDashboard

final class AccountUsageFormatterTests: XCTestCase {
    func testUsageRowsKeepRelativeResetTimingButRemoveVerboseAbsoluteDate() {
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

        let rows = AccountUsageFormatter.rows(
            for: status,
            now: now,
            staleTimestampPrefix: "Usage may be stale · updated ",
            includesAbsoluteDate: false,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(rows.first, AccountUsageRow(label: "5-hour", value: "90% remaining · resets in 3h 15m"))
        XCTAssertFalse(rows.map(\.value).joined().contains("2033"))
    }

    func testAccountUsageRowsIncludeLimitsCountdownsAndBankedResets() {
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

        let rows = AccountUsageFormatter.rows(
            for: .available(CodexAccountUsageSnapshot(usage: usage, fetchedAt: now)),
            now: now,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(rows, [
            AccountUsageRow(label: "5-hour", value: "82% remaining · resets in 2h 15m (18 May 2033 at 5:48)"),
            AccountUsageRow(label: "Weekly", value: "58% remaining · resets in 3d 4h (21 May 2033 at 7:33)"),
            AccountUsageRow(label: "Banked resets", value: "2 available · expires in 1d (19 May 2033 at 3:33)"),
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

        let rows = AccountUsageFormatter.rows(
            for: .stale(snapshot),
            now: now
        )

        XCTAssertEqual(rows.first, AccountUsageRow(label: "5-hour", value: "75% remaining"))
        XCTAssertTrue(rows.last?.value.hasPrefix("Usage may be stale · updated ") == true)
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

        let rows = AccountUsageFormatter.rows(
            for: .stale(snapshot),
            now: now,
            staleTimestampPrefix: "Updated "
        )

        XCTAssertEqual(rows[0], AccountUsageRow(label: "5-hour", value: "90% remaining"))
        XCTAssertEqual(rows[1], AccountUsageRow(label: "Weekly", value: "70% remaining"))
        XCTAssertTrue(rows[2].value.hasPrefix("Updated "))
    }

    func testLoadingAndUnavailableAccountUsageHaveUsefulPlaceholders() {
        XCTAssertEqual(
            AccountUsageFormatter.rows(for: .loading(previous: nil)),
            [AccountUsageRow(label: nil, value: "Loading usage details…")]
        )
        XCTAssertEqual(
            AccountUsageFormatter.rows(for: .unavailable),
            [AccountUsageRow(label: nil, value: "Usage details unavailable")]
        )
    }

}
