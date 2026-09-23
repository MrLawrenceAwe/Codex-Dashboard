import Foundation
import UserNotifications
import XCTest

@testable import CodexDashboard

@MainActor
private final class RecordingDesktopNotificationCenter: DesktopNotificationCenter {
    var authorized = true
    var failedImmediateTitle: String?
    var immediateTitles: [String] = []
    var scheduledRequests: [UNNotificationRequest] = []

    func pendingRequests() async -> [UNNotificationRequest] { [] }
    func removePendingRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func requestAuthorizationIfNeeded() async -> Bool { authorized }

    func add(_ request: UNNotificationRequest) async throws {
        guard request.trigger == nil else {
            scheduledRequests.append(request)
            return
        }
        if request.content.title == failedImmediateTitle {
            failedImmediateTitle = nil
            throw URLError(.cannotConnectToHost)
        }
        immediateTitles.append(request.content.title)
    }
}

@MainActor
private final class SuspendedDesktopNotificationCenter: DesktopNotificationCenter {
    private var started: CheckedContinuation<Void, Never>?
    private var releaseFirstAdd: CheckedContinuation<Void, Never>?
    private(set) var immediateTitles: [String] = []
    private(set) var immediateAttempts = 0

    func pendingRequests() async -> [UNNotificationRequest] { [] }
    func removePendingRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func requestAuthorizationIfNeeded() async -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        guard request.trigger == nil else { return }
        immediateAttempts += 1
        if immediateAttempts == 1 {
            await withCheckedContinuation { continuation in
                releaseFirstAdd = continuation
                started?.resume()
                started = nil
            }
        }
        immediateTitles.append(request.content.title)
    }

    func waitForFirstAdd() async {
        if immediateAttempts > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        releaseFirstAdd?.resume()
        releaseFirstAdd = nil
    }
}

@MainActor
final class DesktopUsageNotifierTests: XCTestCase {
    func testScheduledFallbackDoesNotClaimAnUnverifiedResetTime() async throws {
        let now = Date.now
        let account = SavedAccount(id: UUID(), name: "Personal", createdAt: now,
                                   lastUsedAt: now, accountIdentifier: nil)
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(fiveHour: nil, weekly: CodexUsageWindow(
                usedPercent: 20, resetsAt: now.addingTimeInterval(2 * 60 * 60)
            )),
            fetchedAt: now
        )
        let center = RecordingDesktopNotificationCenter()
        let notifier = DesktopUsageNotifier(notificationCenter: center, userDefaults: try makeDefaults())

        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: snapshot])

        XCTAssertFalse(center.scheduledRequests.isEmpty)
        XCTAssertTrue(center.scheduledRequests.allSatisfy { $0.content.title == "Check Codex usage" })
        XCTAssertTrue(center.scheduledRequests.allSatisfy {
            $0.content.body.contains("was last recorded as")
        })
    }

    func testOverlappingUpdatesDeliverImmediateAlertsOnce() async throws {
        let (account, previous, current) = makeThresholdSnapshots()
        let defaults = try makeDefaults()
        let history = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        history.saveObservations(for: [account], usageByAccountID: [account.id: previous])
        let intermediate = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: nil,
                weekly: CodexUsageWindow(
                    usedPercent: 60,
                    resetsAt: current.usage.weekly?.resetsAt
                )
            ),
            fetchedAt: current.fetchedAt.addingTimeInterval(-1)
        )
        let center = SuspendedDesktopNotificationCenter()
        let notifier = DesktopUsageNotifier(notificationCenter: center, userDefaults: defaults)

        let first = Task { await notifier.updateNotifications(
            for: [account], usageByAccountID: [account.id: intermediate]
        ) }
        await center.waitForFirstAdd()
        let second = Task { await notifier.updateNotifications(
            for: [account], usageByAccountID: [account.id: current]
        ) }
        await Task.yield()
        XCTAssertEqual(center.immediateAttempts, 1)
        center.release()
        await first.value
        await second.value

        XCTAssertEqual(center.immediateTitles, [
            "Codex Weekly: less than 50% remaining",
            "Codex Weekly: less than 20% remaining",
        ])
        XCTAssertEqual(history.observations()[account.id], UsageObservation(usage: current.usage))
    }

    func testRetriesOnlyFailedImmediateAlertsBeforeSavingObservation() async throws {
        let (account, previous, current) = makeThresholdSnapshots()
        let defaults = try makeDefaults()
        let history = UsageNotificationHistory(userDefaults: defaults, channel: .desktop)
        history.saveObservations(for: [account], usageByAccountID: [account.id: previous])
        let center = RecordingDesktopNotificationCenter()
        center.failedImmediateTitle = "Codex Weekly: less than 20% remaining"
        let notifier = DesktopUsageNotifier(notificationCenter: center, userDefaults: defaults)

        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: current])
        XCTAssertEqual(center.immediateTitles.count, 1)
        XCTAssertEqual(history.observations()[account.id], UsageObservation(usage: previous.usage))

        let retryAfterRestart = DesktopUsageNotifier(notificationCenter: center, userDefaults: defaults)
        await retryAfterRestart.updateNotifications(for: [account], usageByAccountID: [account.id: current])
        XCTAssertEqual(center.immediateTitles.count, 2)
        XCTAssertEqual(history.observations()[account.id], UsageObservation(usage: current.usage))

        let reopened = DesktopUsageNotifier(notificationCenter: center, userDefaults: defaults)
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
        let notifier = DesktopUsageNotifier(notificationCenter: center, userDefaults: defaults)

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
        let suite = "DesktopUsageNotifierTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
