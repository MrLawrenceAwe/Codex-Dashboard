import Foundation

@MainActor
protocol PhoneUsageNotifying: AnyObject {
    var isEnabled: Bool { get }
    var topic: String { get }

    func setEnabled(_ enabled: Bool)
    func generateNewTopic()
    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async
    func sendTestNotification() async throws
}

@MainActor
final class NoopPhoneUsageNotifier: PhoneUsageNotifying {
    var isEnabled: Bool { false }
    var topic: String { "" }

    func setEnabled(_ enabled: Bool) {}
    func generateNewTopic() {}
    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {}
    func sendTestNotification() async throws {}
}

@MainActor
final class NtfyUsageNotifier: PhoneUsageNotifying {
    static let enabledKey = "ntfyResetNotificationsEnabled"
    static let topicKey = "ntfyResetNotificationTopic"
    private static let deliveredResetsKey = "ntfyDeliveredAccountResets"
    private static let deliveredImmediateNotificationsKey = "ntfyDeliveredImmediateAccountNotifications"

    private let history: UsageNotificationHistory
    private let userDefaults: UserDefaults
    private let publisher: any NtfyPublishing
    private let now: () -> Date
    private var tasksByIdentifier: [String: Task<Void, Never>] = [:]
    private var scheduledByIdentifier: [String: ScheduledUsageNotification] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        publisher: any NtfyPublishing = NtfyPublisher(),
        now: @escaping () -> Date = { .now }
    ) {
        history = UsageNotificationHistory(userDefaults: userDefaults, channel: .phone)
        self.userDefaults = userDefaults
        self.publisher = publisher
        self.now = now
        if !Self.isValidTopic(userDefaults.string(forKey: Self.topicKey)) {
            userDefaults.set(Self.makeTopic(), forKey: Self.topicKey)
        }
    }

    deinit {
        tasksByIdentifier.values.forEach { $0.cancel() }
    }

    var isEnabled: Bool {
        userDefaults.bool(forKey: Self.enabledKey)
    }

    var topic: String {
        guard let savedTopic = userDefaults.string(forKey: Self.topicKey),
              Self.isValidTopic(savedTopic) else {
            let replacement = Self.makeTopic()
            userDefaults.set(replacement, forKey: Self.topicKey)
            return replacement
        }
        return savedTopic
    }

    func setEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { cancelAllTasks() }
    }

    func generateNewTopic() {
        userDefaults.set(Self.makeTopic(), forKey: Self.topicKey)
    }

    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {
        guard isEnabled else {
            cancelAllTasks()
            return
        }
        let currentDate = now()
        let plan = UsageNotificationPlanner.plan(
            for: accounts,
            usageByAccountID: usageByAccountID,
            previousObservations: history.observations(),
            previousDeadlines: history.deadlines(for: .known),
            sentUpdates: history.deadlines(for: .updates),
            now: currentDate
        )
        history.saveDeadlines(plan.unchangedDeadlines, for: .known)
        let desired = Dictionary(uniqueKeysWithValues: plan.scheduled.map { ($0.identifier, $0) })

        for identifier in Set(tasksByIdentifier.keys).subtracting(desired.keys) {
            cancelTask(identifier)
        }
        for notification in plan.scheduled {
            if deliveredDeadline(for: notification.identifier) == notification.deadlineDate {
                cancelTask(notification.identifier)
                continue
            }
            if scheduledByIdentifier[notification.identifier] == notification { continue }
            cancelTask(notification.identifier)
            scheduledByIdentifier[notification.identifier] = notification
            let delay = max(0, notification.notificationDate.timeIntervalSince(currentDate))
            tasksByIdentifier[notification.identifier] = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                await self?.deliver(notification)
            }
        }
        let immediateNotifications = plan.immediate.filter {
            !deliveredImmediateNotificationIdentifiers().contains($0.identifier)
        }
        for notification in immediateNotifications {
            do {
                try await publisher.publish(topic: topic, title: notification.title, message: notification.body)
                recordDeliveredImmediateNotification(notification.identifier)
            } catch {
                // Leave the previous observation in place so a later refresh can retry.
                return
            }
        }
        history.saveObservations(for: accounts, usageByAccountID: usageByAccountID)
    }

    func sendTestNotification() async throws {
        try await publisher.publish(
            topic: topic,
            title: "Codex Dashboard test",
            message: "Phone usage alerts are connected."
        )
    }

    private func deliver(_ notification: ScheduledUsageNotification) async {
        guard isEnabled, scheduledByIdentifier[notification.identifier] == notification else { return }
        do {
            try await publisher.publish(
                topic: topic,
                title: notification.title,
                message: notification.body
            )
            if notification.identifier.contains("-deadline-update-") {
                history.saveDeadlines([notification], for: .known)
                history.saveDeadlines([notification], for: .updates)
            }
            recordDelivered(notification)
            cancelTask(notification.identifier)
        } catch {
            tasksByIdentifier[notification.identifier] = nil
            scheduledByIdentifier[notification.identifier] = nil
        }
    }

    private func deliveredDeadline(for identifier: String) -> Date? {
        guard let timestamp = userDefaults.dictionary(forKey: Self.deliveredResetsKey)?[identifier]
            as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func recordDelivered(_ notification: ScheduledUsageNotification) {
        var delivered = userDefaults.dictionary(forKey: Self.deliveredResetsKey) ?? [:]
        delivered[notification.identifier] = notification.deadlineDate.timeIntervalSince1970
        userDefaults.set(delivered, forKey: Self.deliveredResetsKey)
    }

    private func deliveredImmediateNotificationIdentifiers() -> Set<String> {
        Set(userDefaults.stringArray(forKey: Self.deliveredImmediateNotificationsKey) ?? [])
    }

    private func recordDeliveredImmediateNotification(_ identifier: String) {
        var identifiers = deliveredImmediateNotificationIdentifiers()
        identifiers.insert(identifier)
        userDefaults.set(Array(identifiers), forKey: Self.deliveredImmediateNotificationsKey)
    }

    private func cancelTask(_ identifier: String) {
        tasksByIdentifier[identifier]?.cancel()
        tasksByIdentifier[identifier] = nil
        scheduledByIdentifier[identifier] = nil
    }

    private func cancelAllTasks() {
        tasksByIdentifier.values.forEach { $0.cancel() }
        tasksByIdentifier = [:]
        scheduledByIdentifier = [:]
    }

    private static func makeTopic() -> String {
        let randomSuffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(16)
        return "codex-dashboard-\(randomSuffix)"
    }

    private static func isValidTopic(_ topic: String?) -> Bool {
        guard let topic, !topic.isEmpty, topic.count <= 64 else { return false }
        return topic.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
}
