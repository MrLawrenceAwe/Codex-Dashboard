import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
final class UsageNotificationRetentionTests: XCTestCase {
    func testPruningKeepsRecentWindowsAndEligibleRetriesAcrossReopening() throws {
        let suite = "UsageHistoryRetention-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = SavedAccount(id: UUID(), name: "Saved", createdAt: now, lastUsedAt: now, codexAccountID: nil)
        let removedID = UUID()
        let old = now.addingTimeInterval(-40 * 86400)
        let recent = now.addingTimeInterval(-86400)
        let current = old.addingTimeInterval(3600)
        func threshold(_ date: Date, _ id: UUID) -> String {
            "codex-dashboard-account-usage-threshold-\(id.uuidString.lowercased())-weekly-50-\(Int(date.timeIntervalSinceReferenceDate))"
        }
        let expiredID = threshold(old, account.id)
        let currentID = threshold(current, account.id)
        let recentID = threshold(recent, account.id)
        let retryID = "codex-dashboard-account-limit-reset-\(account.id.uuidString.lowercased())-weekly-\(Int(old.timeIntervalSinceReferenceDate))"
        let removedAlert = threshold(recent, removedID)
        let bankedID = "codex-dashboard-account-banked-resets-added-\(account.id.uuidString.lowercased())-\(Int(old.timeIntervalSince1970))-2"
        let desktop = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        let phone = UsageNotificationHistory(userDefaults: defaults, channel: .phone)
        for id in [expiredID, currentID, recentID, retryID, removedAlert, bankedID] {
            desktop.recordImmediateDelivery(id)
            phone.recordImmediateDelivery(id)
        }
        let usage = CodexAccountUsage(fiveHour: nil, weekly: CodexUsageWindow(usedPercent: 60, resetsAt: current))
        let snapshots = [account.id: CodexAccountUsageSnapshot(usage: usage, fetchedAt: now)]
        desktop.prune(for: [account], usageByAccountID: snapshots, retainingImmediateIdentifiers: [retryID], now: now)
        XCTAssertEqual(desktop.deliveredImmediateIdentifiers(), [currentID, recentID, retryID])
        XCTAssertEqual(phone.deliveredImmediateIdentifiers().count, 6)
        let reopened = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        reopened.prune(for: [account], usageByAccountID: snapshots, retainingImmediateIdentifiers: [retryID], now: now)
        XCTAssertEqual(reopened.deliveredImmediateIdentifiers(), [currentID, recentID, retryID])
    }

    func testRemovedAccountsArePrunedWithoutDiscardingActiveObservationsDuringAnOutage() throws {
        let suite = "UsageHistoryAccounts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let active = SavedAccount(id: UUID(), name: "Active", createdAt: now, lastUsedAt: now, codexAccountID: nil)
        let removed = SavedAccount(id: UUID(), name: "Removed", createdAt: now, lastUsedAt: now, codexAccountID: nil)
        let usage = CodexAccountUsage(fiveHour: nil, weekly: CodexUsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(86400)))
        let snapshots = Dictionary(uniqueKeysWithValues: [active, removed].map {
            ($0.id, CodexAccountUsageSnapshot(usage: usage, fetchedAt: now))
        })
        let history = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        history.saveObservations(for: [active, removed], usageByAccountID: snapshots)
        let alerts = UsageNotificationPlanner.deadlineNotificationCandidates(for: [active, removed], usageByAccountID: snapshots, now: now)
        history.saveDeadlines(alerts, for: .known)
        history.saveDeadlines(alerts, for: .updates)
        for alert in alerts { history.recordDeadlineDelivery(alert) }
        history.prune(for: [active], usageByAccountID: [:], retainingImmediateIdentifiers: [], now: now)
        XCTAssertEqual(history.observations(), [active.id: usage])
        for kind in [UsageNotificationHistory.DeadlineHistory.known, .updates] {
            XCTAssertFalse(history.deadlines(for: kind).isEmpty)
            XCTAssertTrue(history.deadlines(for: kind).keys.allSatisfy { $0.contains(active.id.uuidString.lowercased()) })
        }
        for alert in alerts {
            XCTAssertEqual(history.deliveredDeadline(for: alert.identifier) != nil, alert.accountID == active.id)
        }
        history.saveObservations(for: [], usageByAccountID: [:])
        XCTAssertTrue(history.observations().isEmpty)
    }
}
