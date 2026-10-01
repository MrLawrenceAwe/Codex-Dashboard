import Foundation

@MainActor
protocol PhoneUsageNotifying: AnyObject {
    var isEnabled: Bool { get }
    var topic: String { get }

    func setDeadlineUsageRefreshHandler(_ handler: @escaping DeadlineUsageRefreshHandler)
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

    func setDeadlineUsageRefreshHandler(_ handler: @escaping DeadlineUsageRefreshHandler) {}
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
    private struct Delivery {
        let notification: ScheduledUsageNotification
        var task: Task<Void, Never>
        var retryAttempt = 0
    }

    static let enabledKey = "ntfyResetNotificationsEnabled"
    static let topicKey = "ntfyResetNotificationTopic"

    private let updateContext: UsageNotificationUpdateCoordinator
    private var history: UsageNotificationHistory { updateContext.history }
    private let userDefaults: UserDefaults
    private let publisher: any NtfyPublishing
    private let now: () -> Date
    private let retryDelay: (Int) -> Duration
    private var deadlineUsageRefresh: DeadlineUsageRefreshHandler?
    private var deliveriesByIdentifier: [String: Delivery] = [:]

    private static let maximumDeliveryAttempts = 6

    init(
        userDefaults: UserDefaults = .standard,
        publisher: any NtfyPublishing = NtfyPublisher(),
        now: @escaping () -> Date = { .now },
        retryDelay: @escaping (Int) -> Duration = { attempt in
            .seconds(min(30 * 60, 60 * (1 << min(attempt - 1, 5))))
        }
    ) {
        updateContext = UsageNotificationUpdateCoordinator(userDefaults: userDefaults, channel: .phone)
        self.userDefaults = userDefaults
        self.publisher = publisher
        self.now = now
        self.retryDelay = retryDelay
        if !Self.isValidTopic(userDefaults.string(forKey: Self.topicKey)) {
            userDefaults.set(Self.makeTopic(), forKey: Self.topicKey)
        }
    }

    deinit {
        deliveriesByIdentifier.values.forEach { $0.task.cancel() }
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

    func setDeadlineUsageRefreshHandler(_ handler: @escaping DeadlineUsageRefreshHandler) {
        deadlineUsageRefresh = handler
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
        await updateContext.perform(
            for: accounts,
            usageByAccountID: usageByAccountID,
            now: now,
            prepare: {
                guard isEnabled else {
                    cancelAllTasks()
                    return false
                }
                return true
            }
        ) { plan, currentDate in
            await apply(plan, for: accounts, usageByAccountID: usageByAccountID, now: currentDate)
        }
    }

    private func apply(
        _ plan: UsageNotificationPlanner.Plan,
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        now currentDate: Date
    ) async {
        let desired = Dictionary(uniqueKeysWithValues: plan.scheduled.map { ($0.identifier, $0) })
        let eligibleDeadlines = (plan.deadlinesWithoutUpdateAlerts + plan.scheduled)
            .reduce(into: [String: Date]()) { result, notification in
                result[notification.sourceIdentifier] = notification.deadlineDate
            }

        for identifier in Set(deliveriesByIdentifier.keys).subtracting(desired.keys) {
            // A due alert stays eligible while it is being delivered or retried.
            // Cancel it if its reset deadline changed or the alert became ineligible.
            if deliveriesByIdentifier[identifier].map({
                eligibleDeadlines[$0.notification.sourceIdentifier] != $0.notification.deadlineDate
            }) != false {
                cancelTask(identifier)
            }
        }
        for notification in plan.scheduled {
            if history.deliveredDeadline(for: notification.identifier) == notification.deadlineDate {
                cancelTask(notification.identifier)
                continue
            }
            // A planner-visible alert (notably a revised deadline) can be
            // retried immediately on this refresh instead of waiting for its
            // delivery backoff. Due alerts absent from the plan retain theirs.
            if let delivery = deliveriesByIdentifier[notification.identifier], delivery.retryAttempt > 0 {
                cancelTask(notification.identifier)
            }
            if deliveriesByIdentifier[notification.identifier]?.notification == notification { continue }
            cancelTask(notification.identifier)
            let delay = max(0, notification.notificationDate.timeIntervalSince(currentDate))
            let task = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                await self?.deliver(notification)
            }
            deliveriesByIdentifier[notification.identifier] = Delivery(notification: notification, task: task)
        }
        let immediateNotifications = plan.immediate.filter {
            !history.deliveredImmediateIdentifiers().contains($0.identifier)
        }
        for notification in immediateNotifications {
            do {
                try await publisher.publish(topic: topic, title: notification.title, message: notification.body)
                history.recordImmediateDelivery(notification.identifier)
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
        guard isEnabled, deliveriesByIdentifier[notification.identifier]?.notification == notification else { return }
        guard let deadlineUsageRefresh,
              let snapshot = await deadlineUsageRefresh(notification.accountID)
        else {
            if isEnabled, deliveriesByIdentifier[notification.identifier]?.notification == notification {
                scheduleRetry(for: notification)
            }
            return
        }
        guard isEnabled, deliveriesByIdentifier[notification.identifier]?.notification == notification else { return }
        guard let refreshed = UsageNotificationPlanner.refreshedContent(
            for: notification, using: snapshot, now: now()
        ) else {
            cancelTask(notification.identifier)
            return
        }
        guard isEnabled, deliveriesByIdentifier[notification.identifier]?.notification == notification else { return }
        do {
            try await publisher.publish(
                topic: topic,
                title: refreshed.title,
                message: refreshed.body
            )
            if notification.identifier.contains("-deadline-update-") {
                history.saveDeadlines([notification], for: .known)
                history.saveDeadlines([notification], for: .updates)
            }
            history.recordDeadlineDelivery(notification)
            cancelTask(notification.identifier)
        } catch {
            scheduleRetry(for: notification)
        }
    }

    private func cancelTask(_ identifier: String) {
        deliveriesByIdentifier.removeValue(forKey: identifier)?.task.cancel()
    }

    private func cancelAllTasks() {
        deliveriesByIdentifier.values.forEach { $0.task.cancel() }
        deliveriesByIdentifier = [:]
    }

    private func scheduleRetry(for notification: ScheduledUsageNotification) {
        let identifier = notification.identifier
        guard var delivery = deliveriesByIdentifier[identifier], delivery.notification == notification else { return }
        let attempt = delivery.retryAttempt + 1
        guard attempt < Self.maximumDeliveryAttempts else {
            cancelTask(identifier)
            return
        }
        delivery.retryAttempt = attempt
        delivery.task = Task { [weak self] in
            try? await Task.sleep(for: self?.retryDelay(attempt) ?? .seconds(0))
            guard !Task.isCancelled else { return }
            await self?.deliver(notification)
        }
        deliveriesByIdentifier[identifier] = delivery
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
