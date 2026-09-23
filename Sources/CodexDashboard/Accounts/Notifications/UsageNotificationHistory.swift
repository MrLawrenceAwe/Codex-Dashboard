import Foundation

/// Shares persistence mechanics while retaining independent desktop/phone delivery history.
@MainActor
struct UsageNotificationHistory {
    enum Channel { case desktop, phone }
    enum DeadlineHistory { case known, updates }

    private let userDefaults: UserDefaults
    private let channel: Channel

    init(userDefaults: UserDefaults, channel: Channel) {
        self.userDefaults = userDefaults
        self.channel = channel
    }

    // These durable keys preserve existing observations and prevent duplicate alerts.
    private var observationsKey: String {
        channel == .desktop ? "accountResetNotificationUsageObservations" : "ntfyAccountUsageObservations"
    }

    private func key(for kind: DeadlineHistory) -> String {
        switch (channel, kind) {
        case (.desktop, .known): "accountResetNotificationKnownDeadlines"
        case (.desktop, .updates): "accountResetNotificationSentDeadlineUpdates"
        case (.phone, .known): "ntfyKnownAccountDeadlines"
        case (.phone, .updates): "ntfySentAccountDeadlineUpdates"
        }
    }

    func deadlines(for kind: DeadlineHistory) -> [String: Date] {
        guard let rawValues = userDefaults.dictionary(forKey: key(for: kind)) else { return [:] }
        return rawValues.reduce(into: [:]) { result, item in
            guard let timestamp = item.value as? Double else { return }
            result[item.key] = Date(timeIntervalSinceReferenceDate: timestamp)
        }
    }

    func saveDeadlines(_ notifications: [ScheduledUsageNotification], for kind: DeadlineHistory) {
        guard !notifications.isEmpty else { return }
        var values = userDefaults.dictionary(forKey: key(for: kind)) ?? [:]
        for notification in notifications {
            values[notification.sourceIdentifier] = notification.deadlineDate.timeIntervalSinceReferenceDate
        }
        userDefaults.set(values, forKey: key(for: kind))
    }

    private var immediateIdentifiersKey: String {
        channel == .desktop
            ? "accountDeliveredImmediateNotifications"
            : "ntfyDeliveredImmediateAccountNotifications"
    }

    func deliveredImmediateIdentifiers() -> Set<String> {
        Set(userDefaults.stringArray(forKey: immediateIdentifiersKey) ?? [])
    }

    func recordImmediateDelivery(_ identifier: String) {
        var identifiers = deliveredImmediateIdentifiers()
        identifiers.insert(identifier)
        userDefaults.set(Array(identifiers), forKey: immediateIdentifiersKey)
    }

    private static let phoneDeliveredDeadlinesKey = "ntfyDeliveredAccountResets"

    func deliveredDeadline(for identifier: String) -> Date? {
        guard channel == .phone,
              let timestamp = userDefaults.dictionary(forKey: Self.phoneDeliveredDeadlinesKey)?[identifier]
                as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func recordDeadlineDelivery(_ notification: ScheduledUsageNotification) {
        guard channel == .phone else { return }
        var delivered = userDefaults.dictionary(forKey: Self.phoneDeliveredDeadlinesKey) ?? [:]
        delivered[notification.identifier] = notification.deadlineDate.timeIntervalSince1970
        userDefaults.set(delivered, forKey: Self.phoneDeliveredDeadlinesKey)
    }

    func observations() -> [UUID: UsageObservation] {
        guard let data = userDefaults.data(forKey: observationsKey) else { return [:] }
        return (try? JSONDecoder().decode([UUID: UsageObservation].self, from: data)) ?? [:]
    }

    func saveObservations(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) {
        let updatedObservations = UsageNotificationPlanner.observations(
            for: accounts,
            usageByAccountID: usageByAccountID
        )
        var allObservations = observations()
        allObservations.merge(updatedObservations) { _, updated in updated }
        guard let data = try? JSONEncoder().encode(allObservations) else { return }
        userDefaults.set(data, forKey: observationsKey)
    }
}
