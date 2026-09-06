import Foundation
import XCTest

@testable import CodexDashboard

private actor RecordingNtfyPublisher: NtfyPublishing {
    struct Message: Equatable {
        let topic: String
        let title: String
        let body: String
    }

    private var messages: [Message] = []

    func publish(topic: String, title: String, message: String) {
        messages.append(Message(topic: topic, title: title, body: message))
    }

    func recordedMessages() -> [Message] { messages }
}

private actor FailOnceNtfyPublisher: NtfyPublishing {
    private var failuresRemaining = 1
    private var messages: [String] = []

    func publish(topic: String, title: String, message: String) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(.cannotConnectToHost)
        }
        messages.append(message)
    }

    func messageCount() -> Int { messages.count }
}

@MainActor
final class NtfyResetNotifierTests: XCTestCase {
    func testDeliversImminentResetWarningOnceWithAccountAndRemainingUsage() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = try makeDefaults()
        defaults.set(true, forKey: NtfyResetNotifier.enabledKey)
        let publisher = RecordingNtfyPublisher()
        let notifier = NtfyResetNotifier(
            userDefaults: defaults,
            publisher: publisher,
            now: { now }
        )
        let account = SavedAccount(
            id: UUID(),
            name: "Personal",
            createdAt: now,
            lastUsedAt: now,
            accountIdentifier: nil
        )
        let usage = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(
                    usedPercent: 18,
                    resetsAt: now.addingTimeInterval(60 * 60 + 0.01)
                ),
                weekly: nil
            ),
            fetchedAt: now
        )

        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: usage])
        for _ in 0..<50 {
            if await publisher.recordedMessages().count == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: usage])
        try? await Task.sleep(for: .milliseconds(20))

        let messages = await publisher.recordedMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.topic, notifier.topic)
        XCTAssertTrue(messages.first?.body.contains("Personal’s 5-hour limit has 82% remaining") == true)
    }

    func testDisabledNotifierDoesNotPublishDueReset() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = try makeDefaults()
        let publisher = RecordingNtfyPublisher()
        let notifier = NtfyResetNotifier(
            userDefaults: defaults,
            publisher: publisher,
            now: { now }
        )
        let account = SavedAccount(
            id: UUID(), name: "Work", createdAt: now, lastUsedAt: now, accountIdentifier: nil
        )
        let usage = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(30 * 60)),
                weekly: nil
            ),
            fetchedAt: now
        )

        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: usage])
        try? await Task.sleep(for: .milliseconds(20))

        let messages = await publisher.recordedMessages()
        XCTAssertTrue(messages.isEmpty)
    }

    func testRetriesARevisedDeadlineAfterPhoneDeliveryFails() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = try makeDefaults()
        defaults.set(true, forKey: NtfyResetNotifier.enabledKey)
        let publisher = FailOnceNtfyPublisher()
        let notifier = NtfyResetNotifier(
            userDefaults: defaults,
            publisher: publisher,
            now: { now }
        )
        let account = SavedAccount(
            id: UUID(), name: "Personal", createdAt: now, lastUsedAt: now, accountIdentifier: nil
        )
        let initialUsage = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(2 * 60 * 60)),
                weekly: nil
            ),
            fetchedAt: now
        )
        let revisedUsage = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(30 * 60)),
                weekly: nil
            ),
            fetchedAt: now
        )

        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: initialUsage])
        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: revisedUsage])
        try? await Task.sleep(for: .seconds(1.1))
        await notifier.updateNotifications(for: [account], usageByAccountID: [account.id: revisedUsage])
        try? await Task.sleep(for: .seconds(1.1))
        for _ in 0..<50 {
            if await publisher.messageCount() == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let messageCount = await publisher.messageCount()
        XCTAssertEqual(messageCount, 1)
    }

    func testGeneratesAFriendlyReplacementTopic() throws {
        let notifier = NtfyResetNotifier(userDefaults: try makeDefaults())
        let initialTopic = notifier.topic

        notifier.generateNewTopic()

        XCTAssertNotEqual(notifier.topic, initialTopic)
        XCTAssertTrue(notifier.topic.hasPrefix("codex-dashboard-"))
        XCTAssertEqual(notifier.topic.count, 32)
    }

    func testReplacesLegacyTopicThatExceedsNtfyLimit() throws {
        let defaults = try makeDefaults()
        defaults.set(
            "codex-dashboard-6a16a2d54e074acebd459180c2c8250e45892ace75b84d98980687ae00809342",
            forKey: NtfyResetNotifier.topicKey
        )

        let notifier = NtfyResetNotifier(userDefaults: defaults)

        XCTAssertTrue(notifier.topic.hasPrefix("codex-dashboard-"))
        XCTAssertEqual(notifier.topic.count, 32)
        XCTAssertEqual(defaults.string(forKey: NtfyResetNotifier.topicKey), notifier.topic)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "NtfyResetNotifierTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
