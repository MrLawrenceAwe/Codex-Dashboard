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
                    weeklyReset: now.addingTimeInterval(96 * 60 * 60),
                    bankedResetExpiration: now.addingTimeInterval(96 * 60 * 60),
                    now: now
                ),
            ],
            now: now
        )

        XCTAssertEqual(notifications.count, 15)
        XCTAssertTrue(notifications.allSatisfy { $0.identifier.hasPrefix("codex-dashboard-account-deadline-") })
        XCTAssertTrue(notifications.contains {
            $0.title == "Codex limit resets in one hour"
                && $0.body.contains("Personal’s 5-hour: 75% left · resets ")
                && $0.body.contains("\n5-hour 75% · Weekly 50% · Banked resets 2")
        })
        XCTAssertTrue(notifications.allSatisfy { $0.body.filter { $0 == "\n" }.count == 1 })
        XCTAssertEqual(
            Set(notifications.filter { $0.identifier.contains("weekly") }.map(\.title)),
            [
                "Codex limit resets in 24 hours",
                "Codex limit resets in 36 hours",
                "Codex limit resets in 48 hours",
                "Codex limit resets in 72 hours",
                "Codex limit resets in 12 hours",
                "Codex limit resets in 5 hours",
                "Codex limit resets in one hour",
            ]
        )
        XCTAssertEqual(
            Set(notifications.filter { $0.identifier.contains("banked-reset-expiry") }.map(\.title)),
            [
                "Banked Codex reset expires in 24 hours",
                "Banked Codex reset expires in 36 hours",
                "Banked Codex reset expires in 48 hours",
                "Banked Codex reset expires in 72 hours",
                "Banked Codex reset expires in 12 hours",
                "Banked Codex reset expires in 5 hours",
                "Banked Codex reset expires in one hour",
            ]
        )
        XCTAssertTrue(notifications.contains {
            $0.body.contains("Personal: 2 banked resets · next expires ")
        })
    }

    func testPlansOneDeadlineUpdateWhenTheWarningTimeHasPassed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let original = AccountResetNotificationPlanner.deliverableNotifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: snapshot(
                    fiveHourReset: now.addingTimeInterval(5 * 60 * 60),
                    weeklyReset: nil,
                    bankedResetExpiration: nil,
                    now: now
                ),
            ],
            now: now
        )
        let revised = AccountResetNotificationPlanner.deliverableNotifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: snapshot(
                    fiveHourReset: now.addingTimeInterval(30 * 60),
                    weeklyReset: nil,
                    bankedResetExpiration: nil,
                    now: now
                ),
            ],
            now: now
        )
        let previousDeadlines = Dictionary(uniqueKeysWithValues: original.map { ($0.sourceIdentifier, $0.deadlineDate) })

        let updates = AccountResetNotificationPlanner.deadlineUpdateNotifications(
            from: revised,
            previousDeadlines: previousDeadlines,
            sentUpdates: [:],
            now: now
        )

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.title, "5-hour reset time changed")
        XCTAssertTrue(updates.first?.body.contains("Personal’s 5-hour reset moved: ") == true)
        XCTAssertTrue(updates.first?.body.contains("\n5-hour 75% · Weekly 50% · Banked resets 0") == true)
        XCTAssertTrue(
            AccountResetNotificationPlanner.deadlineUpdateNotifications(
                from: revised,
                previousDeadlines: previousDeadlines,
                sentUpdates: [revised[0].sourceIdentifier: revised[0].deadlineDate],
                now: now
            ).isEmpty
        )
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

    func testSkipsFiveHourWarningsWhenWeeklyUsageIsZero() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let notifications = AccountResetNotificationPlanner.notifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: CodexAccountUsageSnapshot(
                    usage: CodexAccountUsage(
                        fiveHour: CodexUsageWindow(
                            usedPercent: 25,
                            resetsAt: now.addingTimeInterval(2 * 60 * 60)
                        ),
                        weekly: CodexUsageWindow(
                            usedPercent: 0,
                            resetsAt: now.addingTimeInterval(96 * 60 * 60)
                        ),
                        bankedResets: nil
                    ),
                    fetchedAt: now
                ),
            ],
            now: now
        )

        XCTAssertEqual(notifications.count, 7)
        XCTAssertFalse(notifications.contains { $0.identifier.contains("-5-hour-") })
        XCTAssertTrue(notifications.allSatisfy { $0.identifier.contains("-weekly-") })
    }

    func testPlansAnImmediateAlertWhenUsageDropsBeforeTheKnownReset() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let previous = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(2 * 60 * 60)),
                weekly: CodexUsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))
            ),
            fetchedAt: now.addingTimeInterval(-30)
        )
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(5 * 60 * 60)),
                weekly: CodexUsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)),
                bankedResets: CodexBankedResetSummary(
                    availableCount: 2,
                    nextExpiration: now.addingTimeInterval(24 * 60 * 60)
                )
            ),
            fetchedAt: now
        )

        let alerts = AccountResetNotificationPlanner.resetNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: AccountUsageResetObservation(usage: previous.usage)],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "Codex limit reset early")
        XCTAssertTrue(alerts.first?.body.contains("Personal’s 5-hour: 20% → 90% early") == true)
        XCTAssertTrue(alerts.first?.body.contains("\n5-hour 90% · Weekly 50% · Banked resets 2") == true)
    }

    func testPlansAnImmediateAlertWhenUsageDropsAfterTheScheduledReset() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 0, resetsAt: now.addingTimeInterval(5 * 60 * 60)),
                weekly: CodexUsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)),
                bankedResets: CodexBankedResetSummary(
                    availableCount: 2,
                    nextExpiration: now.addingTimeInterval(24 * 60 * 60)
                )
            ),
            fetchedAt: now
        )
        let previous = AccountUsageResetObservation(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(-30)),
                weekly: nil
            )
        )

        let alerts = AccountResetNotificationPlanner.resetNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: previous],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "Codex limit reset")
        XCTAssertTrue(alerts.first?.body.contains("Personal’s 5-hour reset: 100% left") == true)
        XCTAssertTrue(alerts.first?.body.contains("\n5-hour 100% · Weekly 50% · Banked resets 2") == true)
    }

    func testPlansAWeeklyResetAlertWhenTheNewCycleIsObserved() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: nil,
                weekly: CodexUsageWindow(usedPercent: 99, resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60))
            ),
            fetchedAt: now
        )
        let previous = AccountUsageResetObservation(
            usage: CodexAccountUsage(
                fiveHour: nil,
                weekly: CodexUsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(-30))
            )
        )

        let alerts = AccountResetNotificationPlanner.resetNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: previous],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "Codex limit reset")
        XCTAssertTrue(alerts.first?.body.contains("Personal’s Weekly reset: 1% left") == true)
    }

    func testPlansEachUsageThresholdOncePerWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let reset = now.addingTimeInterval(5 * 60 * 60)
        let previous = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 19, resetsAt: reset),
            weekly: CodexUsageWindow(usedPercent: 49, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))
        )
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 81, resetsAt: reset),
                weekly: CodexUsageWindow(usedPercent: 81, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))
            ),
            fetchedAt: now
        )

        let alerts = AccountResetNotificationPlanner.usageThresholdNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: AccountUsageResetObservation(usage: previous)]
        )

        XCTAssertEqual(alerts.count, 5)
        XCTAssertEqual(
            Set(alerts.map(\.title)),
            [
                "Codex 5-hour usage below 80%",
                "Codex 5-hour usage below 50%",
                "Codex 5-hour usage below 20%",
                "Codex Weekly usage below 50%",
                "Codex Weekly usage below 20%",
            ]
        )
        XCTAssertTrue(alerts.allSatisfy { $0.body.contains(": 19% left") })

        let repeatAlerts = AccountResetNotificationPlanner.usageThresholdNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: AccountUsageResetObservation(usage: current.usage)]
        )
        XCTAssertTrue(repeatAlerts.isEmpty)
    }

    func testDoesNotPlanThresholdAlertsWhenTheWindowHasReset() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(5 * 60 * 60)),
                weekly: nil
            ),
            fetchedAt: now
        )
        let previous = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(-60)),
            weekly: nil
        )

        XCTAssertTrue(
            AccountResetNotificationPlanner.usageThresholdNotifications(
                for: [savedAccount],
                usageByAccountID: [savedAccount.id: current],
                previousObservations: [savedAccount.id: AccountUsageResetObservation(usage: previous)]
            ).isEmpty
        )
    }

    func testPlansThresholdAlertWhenTheResetTimeHasASmallCorrection() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let previous = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 19, resetsAt: now.addingTimeInterval(5 * 60 * 60)),
            weekly: nil
        )
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 21, resetsAt: now.addingTimeInterval(5 * 60 * 60 + 60)),
                weekly: nil
            ),
            fetchedAt: now
        )

        let alerts = AccountResetNotificationPlanner.usageThresholdNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: AccountUsageResetObservation(usage: previous)]
        )

        XCTAssertEqual(alerts.map(\.title), ["Codex 5-hour usage below 80%"])
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
