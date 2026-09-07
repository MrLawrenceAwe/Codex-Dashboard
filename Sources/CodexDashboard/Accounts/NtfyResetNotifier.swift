import Foundation

protocol NtfyPublishing: Sendable {
    func publish(topic: String, title: String, message: String) async throws
}

enum NtfyPublishError: LocalizedError {
    case invalidResponse
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "ntfy returned an invalid response."
        case .rejected(let statusCode):
            return "ntfy rejected the notification (HTTP \(statusCode))."
        }
    }
}

struct NtfyPublisher: NtfyPublishing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func publish(topic: String, title: String, message: String) async throws {
        guard let url = URL(string: "https://ntfy.sh/\(topic)") else {
            throw NtfyPublishError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(message.utf8)
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.setValue("default", forHTTPHeaderField: "X-Priority")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NtfyPublishError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NtfyPublishError.rejected(response.statusCode)
        }
    }
}

@MainActor
protocol PhoneResetNotifying: AnyObject {
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
final class NoopPhoneResetNotifier: PhoneResetNotifying {
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
final class NtfyResetNotifier: PhoneResetNotifying {
    static let enabledKey = "ntfyResetNotificationsEnabled"
    static let topicKey = "ntfyResetNotificationTopic"
    private static let deliveredResetsKey = "ntfyDeliveredAccountResets"
    private static let knownDeadlinesKey = "ntfyKnownAccountDeadlines"
    private static let sentDeadlineUpdatesKey = "ntfySentAccountDeadlineUpdates"
    private static let usageObservationsKey = "ntfyAccountUsageObservations"

    private let userDefaults: UserDefaults
    private let publisher: any NtfyPublishing
    private let now: () -> Date
    private var tasksByIdentifier: [String: Task<Void, Never>] = [:]
    private var scheduledByIdentifier: [String: AccountResetNotification] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        publisher: any NtfyPublishing = NtfyPublisher(),
        now: @escaping () -> Date = { .now }
    ) {
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
        let unexpectedResets = AccountResetNotificationPlanner.unexpectedResetNotifications(
            for: accounts,
            usageByAccountID: usageByAccountID,
            previousObservations: observations(),
            now: currentDate
        )
        let allNotifications = AccountResetNotificationPlanner.deliverableNotifications(
            for: accounts,
            usageByAccountID: usageByAccountID,
            now: currentDate
        )
        let notifications = allNotifications.filter { $0.notificationDate > currentDate }
        let deadlineUpdates = AccountResetNotificationPlanner.deadlineUpdateNotifications(
            from: allNotifications,
            previousDeadlines: deadlines(forKey: Self.knownDeadlinesKey),
            sentUpdates: deadlines(forKey: Self.sentDeadlineUpdatesKey),
            now: currentDate
        )
        let updateSources = Set(deadlineUpdates.map(\.sourceIdentifier))
        saveDeadlines(
            allNotifications.filter { !updateSources.contains($0.sourceIdentifier) },
            forKey: Self.knownDeadlinesKey
        )
        let desired = Dictionary(uniqueKeysWithValues: (notifications + deadlineUpdates).map { ($0.identifier, $0) })

        for identifier in Set(tasksByIdentifier.keys).subtracting(desired.keys) {
            cancelTask(identifier)
        }
        for notification in notifications + deadlineUpdates {
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
        for notification in unexpectedResets {
            do {
                try await publisher.publish(topic: topic, title: notification.title, message: notification.body)
            } catch {
                // Leave the previous observation in place so a later refresh can retry.
                return
            }
        }
        saveObservations(for: accounts, usageByAccountID: usageByAccountID)
    }

    func sendTestNotification() async throws {
        try await publisher.publish(
            topic: topic,
            title: "Codex Dashboard test",
            message: "Phone reset notifications are connected."
        )
    }

    private func deliver(_ notification: AccountResetNotification) async {
        guard isEnabled, scheduledByIdentifier[notification.identifier] == notification else { return }
        do {
            try await publisher.publish(
                topic: topic,
                title: notification.title,
                message: notification.body
            )
            if notification.identifier.contains("-deadline-update-") {
                saveDeadlines([notification], forKey: Self.knownDeadlinesKey)
                saveDeadlines([notification], forKey: Self.sentDeadlineUpdatesKey)
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

    private func recordDelivered(_ notification: AccountResetNotification) {
        var delivered = userDefaults.dictionary(forKey: Self.deliveredResetsKey) ?? [:]
        delivered[notification.identifier] = notification.deadlineDate.timeIntervalSince1970
        userDefaults.set(delivered, forKey: Self.deliveredResetsKey)
    }

    private func deadlines(forKey key: String) -> [String: Date] {
        guard let rawValues = userDefaults.dictionary(forKey: key) else { return [:] }
        return rawValues.reduce(into: [:]) { result, item in
            guard let timestamp = item.value as? Double else { return }
            result[item.key] = Date(timeIntervalSinceReferenceDate: timestamp)
        }
    }

    private func saveDeadlines(_ notifications: [AccountResetNotification], forKey key: String) {
        guard !notifications.isEmpty else { return }
        var values = userDefaults.dictionary(forKey: key) ?? [:]
        for notification in notifications {
            values[notification.sourceIdentifier] = notification.deadlineDate.timeIntervalSinceReferenceDate
        }
        userDefaults.set(values, forKey: key)
    }

    private func observations() -> [UUID: AccountUsageResetObservation] {
        guard let data = userDefaults.data(forKey: Self.usageObservationsKey) else { return [:] }
        return (try? JSONDecoder().decode([UUID: AccountUsageResetObservation].self, from: data)) ?? [:]
    }

    private func saveObservations(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) {
        let updatedObservations = AccountResetNotificationPlanner.observations(
            for: accounts,
            usageByAccountID: usageByAccountID
        )
        var allObservations = observations()
        allObservations.merge(updatedObservations) { _, updated in updated }
        guard let data = try? JSONEncoder().encode(allObservations) else { return }
        userDefaults.set(data, forKey: Self.usageObservationsKey)
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
