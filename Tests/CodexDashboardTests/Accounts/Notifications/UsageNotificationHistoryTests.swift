import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
final class UsageNotificationHistoryTests: XCTestCase {
    func testExistingObservationValuesKeepTheirEncodedShape() throws {
        // The removed observation model encoded these three fields directly.
        struct EarlierObservation: Codable {
            let fiveHour: CodexUsageWindow?
            let weekly: CodexUsageWindow?
            let bankedResets: CodexBankedResetSummary?
        }
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        let previous = EarlierObservation(
            fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: deadline),
            weekly: CodexUsageWindow(usedPercent: 40, resetsAt: deadline),
            bankedResets: CodexBankedResetSummary(availableCount: 2, nextExpiration: deadline)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let saved = try encoder.encode(previous)
        let usage = try JSONDecoder().decode(CodexAccountUsage.self, from: saved)
        XCTAssertEqual(usage.fiveHour, previous.fiveHour)
        XCTAssertEqual(usage.weekly, previous.weekly)
        XCTAssertEqual(usage.bankedResets, previous.bankedResets)
        XCTAssertEqual(try encoder.encode(usage), saved)
    }

    func testDecodesEarlierObservationsWithoutBankedResetData() throws {
        struct EarlierObservation: Encodable {
            let fiveHour: CodexUsageWindow?
            let weekly: CodexUsageWindow?
        }
        let accountID = UUID()
        let data = try JSONEncoder().encode([
            accountID: EarlierObservation(fiveHour: nil, weekly: nil)
        ])
        let observations = try JSONDecoder().decode([UUID: CodexAccountUsage].self, from: data)
        XCTAssertNotNil(observations[accountID])
        XCTAssertNil(observations[accountID]?.bankedResets)
    }

    func testExistingHistoryIsRetainedAndChannelsRemainIndependent() throws {
        let suite = "UsageNotificationHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = SavedAccount(
            id: UUID(), name: "Personal", createdAt: now, lastUsedAt: now, codexAccountID: nil
        )
        let oldUsage = CodexAccountUsage(
            fiveHour: nil,
            weekly: CodexUsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(96 * 60 * 60))
        )
        let oldObservations = [account.id: oldUsage]
        defaults.set(try JSONEncoder().encode(oldObservations), forKey: "accountResetNotificationUsageObservations")
        defaults.set(["existing": now.timeIntervalSinceReferenceDate], forKey: "accountResetNotificationKnownDeadlines")
        let desktop = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        let phone = UsageNotificationHistory(userDefaults: defaults, channel: .phone)
        XCTAssertEqual(desktop.observations(), oldObservations)
        XCTAssertEqual(desktop.deadlines(for: .known), ["existing": now])
        XCTAssertTrue(phone.observations().isEmpty)
        XCTAssertTrue(phone.deadlines(for: .known).isEmpty)

        let currentUsage = CodexAccountUsage(
            fiveHour: nil,
            weekly: CodexUsageWindow(usedPercent: 30, resetsAt: now.addingTimeInterval(96 * 60 * 60))
        )
        let snapshots = [account.id: CodexAccountUsageSnapshot(usage: currentUsage, fetchedAt: now)]
        desktop.saveObservations(for: [account], usageByAccountID: snapshots)
        XCTAssertEqual(desktop.observations()[account.id], currentUsage)
        XCTAssertTrue(phone.observations().isEmpty, "Desktop success must not acknowledge phone delivery")

        let alerts = UsageNotificationPlanner.deliverableNotifications(
            for: [account], usageByAccountID: snapshots, now: now
        ).filter { $0.notificationDate > now }
        phone.saveDeadlines(alerts, for: .updates)
        XCTAssertFalse(phone.deadlines(for: .updates).isEmpty)
        XCTAssertTrue(desktop.deadlines(for: .updates).isEmpty)
        XCTAssertEqual(desktop.deadlines(for: .known), ["existing": now])

        let reopenedPhone = UsageNotificationHistory(userDefaults: defaults, channel: .phone)
        XCTAssertEqual(reopenedPhone.deadlines(for: .updates), phone.deadlines(for: .updates))
    }
}
