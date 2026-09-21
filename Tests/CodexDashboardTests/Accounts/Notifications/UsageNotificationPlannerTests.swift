import Foundation
import XCTest

@testable import CodexDashboard

final class UsageNotificationPlannerTests: XCTestCase {
    func testKeepsWeeklyResetAndBankedExpiryRemindersWhileWeeklyUsageIsExhausted() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let weeklyReset = now.addingTimeInterval(96 * 60 * 60)
        let previous = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(5 * 60 * 60)),
            weekly: CodexUsageWindow(usedPercent: 10, resetsAt: weeklyReset)
        )
        for usedPercent in [100, 101] {
            let current = CodexAccountUsageSnapshot(
                usage: CodexAccountUsage(
                    fiveHour: CodexUsageWindow(usedPercent: 90, resetsAt: previous.fiveHour?.resetsAt),
                    weekly: CodexUsageWindow(usedPercent: usedPercent, resetsAt: weeklyReset),
                    bankedResets: CodexBankedResetSummary(availableCount: 2, nextExpiration: weeklyReset)
                ),
                fetchedAt: now
            )
            let plan = UsageNotificationPlanner.plan(
                for: [savedAccount], usageByAccountID: [savedAccount.id: current],
                previousObservations: [savedAccount.id: UsageObservation(usage: previous)],
                previousDeadlines: [:], sentUpdates: [:], now: now
            )
            XCTAssertEqual(plan.scheduled.count, 14)
            XCTAssertEqual(
                plan.scheduled.filter { $0.identifier.contains("-weekly-") }.count,
                7
            )
            XCTAssertEqual(
                plan.scheduled.filter { $0.identifier.contains("banked-reset-expiry") }.count,
                7
            )
            let weeklyReminder = plan.scheduled.first { $0.identifier.contains("-weekly-48h") }
            XCTAssertTrue(
                weeklyReminder.flatMap {
                    UsageNotificationPlanner.refreshedContent(for: $0, using: current, now: now)
                }?.body.contains("Weekly: 0% left") == true
            )
            XCTAssertTrue(plan.immediate.isEmpty)
            XCTAssertEqual(plan.unchangedDeadlines.count, 14)
        }
    }

    func testResumesAlertsWhenExhaustedWeeklyUsageResets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let current = snapshot(
            fiveHourReset: nil, weeklyReset: now.addingTimeInterval(7 * 24 * 60 * 60),
            bankedResetExpiration: now.addingTimeInterval(96 * 60 * 60), now: now
        )
        let previous = CodexAccountUsage(
            fiveHour: nil, weekly: CodexUsageWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(-30))
        )
        let plan = UsageNotificationPlanner.plan(
            for: [savedAccount], usageByAccountID: [savedAccount.id: current],
            previousObservations: [savedAccount.id: UsageObservation(usage: previous)],
            previousDeadlines: [:], sentUpdates: [:], now: now
        )
        XCTAssertEqual(plan.scheduled.count, 14)
        XCTAssertEqual(plan.immediate.count, 1)
        XCTAssertEqual(plan.immediate.first?.title, "Codex limit reset")
    }

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
        XCTAssertTrue(notifications.allSatisfy { $0.identifier.hasPrefix("codex-dashboard-account-deadline-v2-") })
        XCTAssertFalse(notifications.contains { $0.identifier.contains("-5-hour-") })
        XCTAssertTrue(notifications.allSatisfy { !$0.body.contains("\n") })
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
            $0.body.contains("Personal’s next banked reset expires ")
        })
        XCTAssertTrue(notifications.filter { $0.identifier.contains("weekly") }.allSatisfy {
            !$0.body.contains("resets at ") && !$0.body.contains("resets tomorrow at ")
        })
    }

    func testScheduledResetReminderDoesNotFreezeUsageSnapshotIntoBody() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let weeklyReset = now.addingTimeInterval(96 * 60 * 60)

        func weeklyReminder(usedPercent: Int) -> ScheduledUsageNotification? {
            let usage = CodexAccountUsageSnapshot(
                usage: CodexAccountUsage(
                    fiveHour: CodexUsageWindow(
                        usedPercent: usedPercent,
                        resetsAt: now.addingTimeInterval(5 * 60 * 60)
                    ),
                    weekly: CodexUsageWindow(usedPercent: usedPercent, resetsAt: weeklyReset),
                    bankedResets: CodexBankedResetSummary(availableCount: 0, nextExpiration: nil)
                ),
                fetchedAt: now
            )
            return UsageNotificationPlanner.notifications(
                for: [savedAccount],
                usageByAccountID: [savedAccount.id: usage],
                now: now
            ).first { $0.identifier.contains("-weekly-48h") }
        }

        let earlySnapshot = weeklyReminder(usedPercent: 3)
        let laterSnapshot = weeklyReminder(usedPercent: 83)

        XCTAssertEqual(earlySnapshot?.body, laterSnapshot?.body)
        XCTAssertFalse(earlySnapshot?.body.contains("%") == true)
        XCTAssertTrue(earlySnapshot?.body.hasPrefix("Personal’s Weekly limit resets ") == true)
    }

    func testRefreshesScheduledReminderFromMatchingDeliveryTimeSnapshot() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let weeklyReset = now.addingTimeInterval(48 * 60 * 60)
        let scheduledSnapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 3, resetsAt: now.addingTimeInterval(5 * 60 * 60)),
                weekly: CodexUsageWindow(usedPercent: 3, resetsAt: weeklyReset)
            ),
            fetchedAt: now
        )
        let notification = try XCTUnwrap(
            UsageNotificationPlanner.deliverableNotifications(
                for: [savedAccount],
                usageByAccountID: [savedAccount.id: scheduledSnapshot],
                now: now
            ).first { $0.identifier.contains("-weekly-48h") }
        )
        let deliverySnapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(3 * 60 * 60)),
                weekly: CodexUsageWindow(usedPercent: 83, resetsAt: weeklyReset),
                bankedResets: CodexBankedResetSummary(availableCount: 1, nextExpiration: nil)
            ),
            fetchedAt: now.addingTimeInterval(60)
        )

        let refreshed = UsageNotificationPlanner.refreshedContent(
            for: notification,
            using: deliverySnapshot,
            now: now.addingTimeInterval(60)
        )

        XCTAssertTrue(refreshed?.body.contains("Personal’s Weekly: 17% left") == true)
        XCTAssertTrue(refreshed?.body.contains("⏱ 5-hour 60% · 📅 Weekly 17% · 🎟 Banked 1") == true)
    }

    func testRejectsDeliveryTimeSnapshotForChangedDeadline() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let savedAccount = account(named: "Personal")
        let scheduledReset = now.addingTimeInterval(48 * 60 * 60)
        let notification = try XCTUnwrap(
            UsageNotificationPlanner.deliverableNotifications(
                for: [savedAccount],
                usageByAccountID: [
                    savedAccount.id: CodexAccountUsageSnapshot(
                        usage: CodexAccountUsage(
                            fiveHour: nil,
                            weekly: CodexUsageWindow(usedPercent: 3, resetsAt: scheduledReset)
                        ),
                        fetchedAt: now
                    ),
                ],
                now: now
            ).first { $0.identifier.contains("-weekly-48h") }
        )
        let changed = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: nil,
                weekly: CodexUsageWindow(
                    usedPercent: 83,
                    resetsAt: scheduledReset.addingTimeInterval(10 * 60)
                )
            ),
            fetchedAt: now.addingTimeInterval(60)
        )

        XCTAssertNil(UsageNotificationPlanner.refreshedContent(for: notification, using: changed, now: now))
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
