import XCTest

@testable import CodexDashboard

final class AccountPopoverModelsTests: XCTestCase {
    func testUsageTitlesKeepRelativeResetTimingButRemoveVerboseAbsoluteDate() {
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

        let titles = AccountPopoverUsageFormatter.titles(
            for: status,
            staleLabel: "Usage may be stale",
            now: now,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(titles.first, "5-hour: 90% remaining · resets in 3h 15m")
        XCTAssertFalse(titles.joined().contains("2033"))
    }
}
