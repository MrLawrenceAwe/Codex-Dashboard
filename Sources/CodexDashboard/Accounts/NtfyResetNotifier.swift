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
        let notifications = AccountResetNotificationPlanner.deliverableNotifications(
            for: accounts,
            usageByAccountID: usageByAccountID,
            now: currentDate
        )
        let desired = Dictionary(uniqueKeysWithValues: notifications.map { ($0.identifier, $0) })

        for identifier in Set(tasksByIdentifier.keys).subtracting(desired.keys) {
            cancelTask(identifier)
        }
        for notification in notifications {
            if deliveredReset(for: notification.identifier) == notification.resetDate {
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
                title: "Codex limit resets in one hour",
                message: "\(notification.accountName)’s \(notification.windowName) limit has \(notification.remainingPercent)% remaining and will reset in one hour."
            )
            recordDelivered(notification)
            cancelTask(notification.identifier)
        } catch {
            tasksByIdentifier[notification.identifier] = nil
            scheduledByIdentifier[notification.identifier] = nil
        }
    }

    private func deliveredReset(for identifier: String) -> Date? {
        guard let timestamp = userDefaults.dictionary(forKey: Self.deliveredResetsKey)?[identifier]
            as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func recordDelivered(_ notification: AccountResetNotification) {
        var delivered = userDefaults.dictionary(forKey: Self.deliveredResetsKey) ?? [:]
        delivered[notification.identifier] = notification.resetDate.timeIntervalSince1970
        userDefaults.set(delivered, forKey: Self.deliveredResetsKey)
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
