import Foundation
import XCTest

@testable import CodexDashboard

final class AccountResetNotifierTests: XCTestCase {
    func testPlansOneHourNotificationsForEveryAccountAndResetWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = account(named: "Personal")
        let second = account(named: "Work")
        let notifications = AccountResetNotificationPlanner.notifications(
            for: [first, second],
            usageByAccountID: [
                first.id: snapshot(fiveHourReset: now.addingTimeInterval(2 * 60 * 60), weeklyReset: nil, now: now),
                second.id: snapshot(fiveHourReset: now.addingTimeInterval(5 * 60 * 60), weeklyReset: now.addingTimeInterval(8 * 24 * 60 * 60), now: now),
            ],
            now: now
        )

        XCTAssertEqual(notifications.count, 3)
        XCTAssertEqual(Set(notifications.map(\.accountName)), ["Personal", "Work"])
        XCTAssertEqual(notifications.map(\.notificationDate).min(), now.addingTimeInterval(60 * 60))
        XCTAssertEqual(Set(notifications.map(\.remainingPercent)), [50, 75])
        XCTAssertTrue(notifications.allSatisfy { $0.identifier.hasPrefix("codex-dashboard-account-reset-") })
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
        now: Date
    ) -> CodexAccountUsageSnapshot {
        CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 25, resetsAt: fiveHourReset),
                weekly: CodexUsageWindow(usedPercent: 50, resetsAt: weeklyReset)
            ),
            fetchedAt: now
        )
    }
}
