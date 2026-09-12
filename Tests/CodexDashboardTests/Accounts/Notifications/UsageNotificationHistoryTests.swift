import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
final class UsageNotificationHistoryTests: XCTestCase {
    func testExistingHistoryIsRetainedAndChannelsRemainIndependent() throws {
        let suite = "UsageNotificationHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = SavedAccount(
            id: UUID(), name: "Personal", createdAt: now, lastUsedAt: now, accountIdentifier: nil
        )
        let oldUsage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(7200)), weekly: nil
        )
        let oldObservations = [account.id: UsageObservation(usage: oldUsage)]
        defaults.set(try JSONEncoder().encode(oldObservations), forKey: "accountResetNotificationUsageObservations")
        defaults.set(["existing": now.timeIntervalSinceReferenceDate], forKey: "accountResetNotificationKnownDeadlines")
        let desktop = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        let phone = UsageNotificationHistory(userDefaults: defaults, channel: .phone)
        XCTAssertEqual(desktop.observations(), oldObservations)
        XCTAssertEqual(desktop.deadlines(for: .known), ["existing": now])
        XCTAssertTrue(phone.observations().isEmpty)
        XCTAssertTrue(phone.deadlines(for: .known).isEmpty)

        let currentUsage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(usedPercent: 30, resetsAt: now.addingTimeInterval(7200)), weekly: nil
        )
        let snapshots = [account.id: CodexAccountUsageSnapshot(usage: currentUsage, fetchedAt: now)]
        desktop.saveObservations(for: [account], usageByAccountID: snapshots)
        XCTAssertEqual(desktop.observations()[account.id], UsageObservation(usage: currentUsage))
        XCTAssertTrue(phone.observations().isEmpty, "Desktop success must not acknowledge phone delivery")

        let alerts = UsageNotificationPlanner.notifications(for: [account], usageByAccountID: snapshots, now: now)
        phone.saveDeadlines(alerts, for: .updates)
        XCTAssertFalse(phone.deadlines(for: .updates).isEmpty)
        XCTAssertTrue(desktop.deadlines(for: .updates).isEmpty)
        XCTAssertEqual(desktop.deadlines(for: .known), ["existing": now])

        let reopenedPhone = UsageNotificationHistory(userDefaults: defaults, channel: .phone)
        XCTAssertEqual(reopenedPhone.deadlines(for: .updates), phone.deadlines(for: .updates))
    }
}
