import Foundation
import XCTest

@testable import CodexDashboard

final class AccountResetNotifierTests: XCTestCase {
    func testPlansWeeklyAndBankedExpiryWarningsAtEveryRequestedLeadTime() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = account(named: "Personal")
        let notifications = AccountResetNotificationPlanner.notifications(
            for: [account],
            usageByAccountID: [
                account.id: snapshot(
                    fiveHourReset: now.addingTimeInterval(2 * 60 * 60),
                    weeklyReset: now.addingTimeInterval(48 * 60 * 60),
                    bankedResetExpiration: now.addingTimeInterval(30 * 60 * 60),
                    now: now
                ),
            ],
            now: now
        )

        XCTAssertEqual(notifications.count, 7)
        XCTAssertTrue(notifications.allSatisfy { $0.identifier.hasPrefix("codex-dashboard-account-deadline-") })
        XCTAssertTrue(notifications.contains {
            $0.title == "Codex limit resets in one hour"
                && $0.body == "Personal’s 5-hour limit has 75% remaining and will reset in one hour."
        })
        XCTAssertEqual(
            Set(notifications.filter { $0.identifier.contains("weekly") }.map(\.title)),
            [
                "Codex limit resets in 24 hours",
                "Codex limit resets in 5 hours",
                "Codex limit resets in one hour",
            ]
        )
        XCTAssertEqual(
            Set(notifications.filter { $0.identifier.contains("banked-reset-expiry") }.map(\.title)),
            [
                "Banked Codex reset expires in 24 hours",
                "Banked Codex reset expires in 5 hours",
                "Banked Codex reset expires in one hour",
            ]
        )
        XCTAssertTrue(notifications.contains {
            $0.body == "Personal has 2 banked resets available; the next one expires in 5 hours."
        })
    }

    func testSkipsResetNotificationsWhoseOneHourWarningHasAlreadyPassed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let notifications = AccountResetNotificationPlanner.notifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: snapshot(
                    fiveHourReset: now.addingTimeInterval(45 * 60),
                    weeklyReset: nil,
                    bankedResetExpiration: nil,
                    now: now
                ),
            ],
            now: now
        )

        XCTAssertTrue(notifications.isEmpty)
    }

    private func account(named name: String) -> SavedAccount {
        SavedAccount(id: UUID(), name: name, createdAt: .now, lastUsedAt: .now, accountIdentifier: nil)
    }

    private func snapshot(
        fiveHourReset: Date?,
        weeklyReset: Date?,
        bankedResetExpiration: Date?,
        now: Date
    ) -> CodexAccountUsageSnapshot {
        CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 25, resetsAt: fiveHourReset),
                weekly: CodexUsageWindow(usedPercent: 50, resetsAt: weeklyReset),
                bankedResets: CodexBankedResetSummary(
                    availableCount: bankedResetExpiration == nil ? 0 : 2,
                    nextExpiration: bankedResetExpiration
                )
            ),
            fetchedAt: now
        )
    }
}
