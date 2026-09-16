import Foundation
import XCTest

@testable import CodexDashboard

final class UsageNotificationPlannerTests: XCTestCase {
    func testPlansWeeklyAndBankedExpiryWarningsAtEveryRequestedLeadTime() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = account(named: "Personal")
        let notifications = UsageNotificationPlanner.notifications(
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

        XCTAssertEqual(notifications.count, 14)
        XCTAssertTrue(notifications.allSatisfy { $0.identifier.hasPrefix("codex-dashboard-account-deadline-") })
        XCTAssertFalse(notifications.contains { $0.identifier.contains("-5-hour-") })
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
        XCTAssertTrue(notifications.filter { $0.identifier.contains("weekly") }.allSatisfy {
            !$0.body.contains("resets at ") && !$0.body.contains("resets tomorrow at ")
        })
    }

    func testPlansOneDeadlineUpdateWhenTheWarningTimeHasPassed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let original = UsageNotificationPlanner.deliverableNotifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: snapshot(
                    fiveHourReset: nil,
                    weeklyReset: now.addingTimeInterval(5 * 60 * 60),
                    bankedResetExpiration: nil,
                    now: now
                ),
            ],
            now: now
        )
        let revised = UsageNotificationPlanner.deliverableNotifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: snapshot(
                    fiveHourReset: nil,
                    weeklyReset: now.addingTimeInterval(30 * 60),
                    bankedResetExpiration: nil,
                    now: now
                ),
            ],
            now: now
        )
        let previousDeadlines = Dictionary(uniqueKeysWithValues: original.map { ($0.sourceIdentifier, $0.deadlineDate) })

        let updates = UsageNotificationPlanner.deadlineUpdateNotifications(
            from: revised,
            previousDeadlines: previousDeadlines,
            sentUpdates: [:],
            now: now
        )

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.title, "Weekly reset time changed")
        XCTAssertTrue(
            UsageNotificationPlanner.deadlineUpdateNotifications(
                from: revised,
                previousDeadlines: previousDeadlines,
                sentUpdates: [revised[0].sourceIdentifier: revised[0].deadlineDate],
                now: now
            ).isEmpty
        )
    }

    func testDoesNotPlanDeadlineUpdateForSmallResetTimeCorrection() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let reset = now.addingTimeInterval(30 * 60)
        let notifications = UsageNotificationPlanner.deliverableNotifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: snapshot(
                    fiveHourReset: nil,
                    weeklyReset: reset,
                    bankedResetExpiration: nil,
                    now: now
                ),
            ],
            now: now
        )

        let updates = UsageNotificationPlanner.deadlineUpdateNotifications(
            from: notifications,
            previousDeadlines: [notifications[0].sourceIdentifier: reset.addingTimeInterval(-60)],
            sentUpdates: [:],
            now: now
        )

        XCTAssertTrue(updates.isEmpty)
    }

    func testDoesNotRepeatDeadlineUpdateForSmallCorrectionAfterDelivery() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let reset = now.addingTimeInterval(30 * 60)
        let notifications = UsageNotificationPlanner.deliverableNotifications(
            for: [savedAccount],
            usageByAccountID: [
                savedAccount.id: snapshot(
                    fiveHourReset: nil,
                    weeklyReset: reset,
                    bankedResetExpiration: nil,
                    now: now
                ),
            ],
            now: now
        )

        let updates = UsageNotificationPlanner.deadlineUpdateNotifications(
            from: notifications,
            previousDeadlines: [notifications[0].sourceIdentifier: reset.addingTimeInterval(-10 * 60)],
            sentUpdates: [notifications[0].sourceIdentifier: reset.addingTimeInterval(-60)],
            now: now
        )

        XCTAssertTrue(updates.isEmpty)
    }

    func testDoesNotScheduleFiveHourResetWarnings() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let notifications = UsageNotificationPlanner.notifications(
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

    func testSkipsAllFiveHourImmediateAlertsWhenWeeklyUsageIsExhausted() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let previous = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(2 * 60 * 60)),
            weekly: CodexUsageWindow(usedPercent: 99, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))
        )
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(5 * 60 * 60)),
                weekly: CodexUsageWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))
            ),
            fetchedAt: now
        )
        let observations = [savedAccount.id: UsageObservation(usage: previous)]

        XCTAssertTrue(
            UsageNotificationPlanner.resetNotifications(
                for: [savedAccount],
                usageByAccountID: [savedAccount.id: current],
                previousObservations: observations,
                now: now
            ).isEmpty
        )
        XCTAssertTrue(
            UsageNotificationPlanner.usageThresholdNotifications(
                for: [savedAccount],
                usageByAccountID: [savedAccount.id: current],
                previousObservations: observations,
                now: now
            ).isEmpty
        )
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

        let alerts = UsageNotificationPlanner.resetNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: UsageObservation(usage: previous.usage)],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "Codex limit reset early")
        XCTAssertTrue(alerts.first?.body.contains("Personal’s 5-hour: 20% → 90% early") == true)
        XCTAssertTrue(alerts.first?.body.contains("\n⏱ 5-hour 90% · 📅 Weekly 50% · 🎟 Banked 2") == true)
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
        let previous = UsageObservation(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(-30)),
                weekly: nil
            )
        )

        let alerts = UsageNotificationPlanner.resetNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: previous],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "Codex limit reset")
        XCTAssertTrue(alerts.first?.body.contains("Personal’s 5-hour reset: 100% left") == true)
        XCTAssertTrue(alerts.first?.body.contains("\n⏱ 5-hour 100% · 📅 Weekly 50% · 🎟 Banked 2") == true)
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
        let previous = UsageObservation(
            usage: CodexAccountUsage(
                fiveHour: nil,
                weekly: CodexUsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(-30))
            )
        )

        let alerts = UsageNotificationPlanner.resetNotifications(
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

        let alerts = UsageNotificationPlanner.usageThresholdNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: UsageObservation(usage: previous)],
            now: now
        )

        XCTAssertEqual(alerts.count, 4)
        XCTAssertEqual(
            Set(alerts.map(\.title)),
            [
                "Codex 5-hour: less than 50% remaining",
                "Codex 5-hour: less than 20% remaining",
                "Codex Weekly: less than 50% remaining",
                "Codex Weekly: less than 20% remaining",
            ]
        )
        XCTAssertTrue(alerts.allSatisfy { $0.body.contains(": 19% left") })

        let repeatAlerts = UsageNotificationPlanner.usageThresholdNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: UsageObservation(usage: current.usage)],
            now: now
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
            UsageNotificationPlanner.usageThresholdNotifications(
                for: [savedAccount],
                usageByAccountID: [savedAccount.id: current],
                previousObservations: [savedAccount.id: UsageObservation(usage: previous)],
                now: now
            ).isEmpty
        )
    }

    func testSkipsTheFiveHourEightyPercentThresholdWhenTheResetTimeHasASmallCorrection() {
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

        let alerts = UsageNotificationPlanner.usageThresholdNotifications(
            for: [savedAccount],
            usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: UsageObservation(usage: previous)],
            now: now
        )

        XCTAssertTrue(alerts.isEmpty)
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
