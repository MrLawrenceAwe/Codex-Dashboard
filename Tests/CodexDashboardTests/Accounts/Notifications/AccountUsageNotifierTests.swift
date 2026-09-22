import Foundation
import UserNotifications
import XCTest

@testable import CodexDashboard

@MainActor
private final class RecordingDesktopNotificationCenter: DesktopNotificationCenter {
    var authorized = true
    var failedImmediateTitle: String?
    var immediateTitles: [String] = []

    func pendingRequests() async -> [UNNotificationRequest] { [] }
    func removePendingRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func isAuthorized() async -> Bool { authorized }

    func add(_ request: UNNotificationRequest) async throws {
        guard request.trigger == nil else { return }
        if request.content.title == failedImmediateTitle {
            failedImmediateTitle = nil
            throw URLError(.cannotConnectToHost)
        }
        immediateTitles.append(request.content.title)
    }
}

@MainActor
final class AccountUsageNotifierTests: XCTestCase {
    func testRetriesOnlyFailedImmediateAlertsBeforeSavingObservation() async throws {
        let (account, previous, current) = makeThresholdSnapshots()
        let defaults = try makeDefaults()
        let history = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        history.saveObservations(for: [account], usageByAccountID: [account.id: previous])
        let center = RecordingDesktopNotificationCenter()
        center.failedImmediateTitle = "Codex Weekly: less than 20% remaining"
        let notifier = AccountUsageNotifier(notificationCenter: center, userDefaults: defaults)

        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: current])
        XCTAssertEqual(center.immediateTitles.count, 1)
        XCTAssertEqual(history.observations()[account.id], UsageObservation(usage: previous.usage))

        let retryAfterRestart = AccountUsageNotifier(notificationCenter: center, userDefaults: defaults)
        await retryAfterRestart.updateNotifications(for: [account], usageByAccountID: [account.id: current])
        XCTAssertEqual(center.immediateTitles.count, 2)
        XCTAssertEqual(history.observations()[account.id], UsageObservation(usage: current.usage))

        let reopened = AccountUsageNotifier(notificationCenter: center, userDefaults: defaults)
        await reopened.updateNotifications(for: [account], usageByAccountID: [account.id: current])
        XCTAssertEqual(center.immediateTitles.count, 2)
    }

    func testUnauthorizedImmediateAlertRemainsPendingUntilPermissionReturns() async throws {
        let (account, previous, current) = makeThresholdSnapshots()
        let defaults = try makeDefaults()
        let history = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        history.saveObservations(for: [account], usageByAccountID: [account.id: previous])
        let center = RecordingDesktopNotificationCenter()
        center.authorized = false
        let notifier = AccountUsageNotifier(notificationCenter: center, userDefaults: defaults)

        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: current])
        XCTAssertTrue(center.immediateTitles.isEmpty)
        XCTAssertEqual(history.observations()[account.id], UsageObservation(usage: previous.usage))

        center.authorized = true
        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: current])
        XCTAssertEqual(center.immediateTitles.count, 2)
        XCTAssertEqual(history.observations()[account.id], UsageObservation(usage: current.usage))
    }

    private func makeThresholdSnapshots() -> (
        SavedAccount, CodexAccountUsageSnapshot, CodexAccountUsageSnapshot
    ) {
        let now = Date.now
        let account = SavedAccount(
            id: UUID(), name: "Personal", createdAt: now, lastUsedAt: now,
            accountIdentifier: nil
        )
        let reset = now.addingTimeInterval(3 * 24 * 60 * 60)
        let previous = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: nil,
                weekly: CodexUsageWindow(usedPercent: 40, resetsAt: reset)
            ),
            fetchedAt: now
        )
        let current = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: nil,
                weekly: CodexUsageWindow(usedPercent: 85, resetsAt: reset)
            ),
            fetchedAt: now
        )
        return (account, previous, current)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "AccountUsageNotifierTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
