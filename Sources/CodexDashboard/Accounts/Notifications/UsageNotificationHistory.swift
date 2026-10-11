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

    // Thirty days exceeds both usage windows. Keep currently eligible alerts
    // and observed windows even when snapshots are older, so retries cannot
    // become duplicate deliveries after pruning.
    func prune(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        retainingImmediateIdentifiers: Set<String>,
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let savedObservations = observations()
        let activeIDs = Set(accounts.map(\.id))
        let accountWindows = Dictionary(uniqueKeysWithValues: accounts.map { account in
            let usages = [usageByAccountID[account.id]?.usage, savedObservations[account.id]].compactMap { $0 }
            return (account.id.uuidString.lowercased(), usages.flatMap {
                [$0.fiveHour?.resetsAt, $0.weekly?.resetsAt].compactMap { $0 }
            })
        })
        func accountID(in identifier: String) -> String? {
            accountWindows.keys.first { identifier.contains("-\($0)-") }
        }
        let retained = deliveredImmediateIdentifiers().filter { identifier in
            guard let id = accountID(in: identifier) else { return false }
            if retainingImmediateIdentifiers.contains(identifier) { return true }
            let parts = identifier.split(separator: "-")
            let banked = identifier.hasPrefix("codex-dashboard-account-banked-resets-added-")
            guard let timestamp = Double(String(banked ? parts.dropLast().last ?? "" : parts.last ?? "")) else { return false }
            let date = banked ? Date(timeIntervalSince1970: timestamp) : Date(timeIntervalSinceReferenceDate: timestamp)
            return date >= cutoff || accountWindows[id, default: []].contains {
                abs($0.timeIntervalSince(date)) < 1
            }
        }
        userDefaults.set(Array(retained), forKey: immediateIdentifiersKey)
        for kind in [DeadlineHistory.known, .updates] {
            let retained = deadlines(for: kind).filter { accountID(in: $0.key) != nil }
            userDefaults.set(retained.mapValues(\.timeIntervalSinceReferenceDate), forKey: key(for: kind))
        }
        let delivered = userDefaults.dictionary(forKey: deliveredDeadlinesKey) ?? [:]
        userDefaults.set(delivered.filter { accountID(in: $0.key) != nil }, forKey: deliveredDeadlinesKey)
        if let data = try? JSONEncoder().encode(savedObservations.filter { activeIDs.contains($0.key) }) {
            userDefaults.set(data, forKey: observationsKey)
        }
    }

    private var deliveredDeadlinesKey: String {
        channel == .desktop ? "accountDeliveredDeadlineNotifications" : "ntfyDeliveredAccountResets"
    }

    func deliveredDeadline(for identifier: String) -> Date? {
        guard let timestamp = userDefaults.dictionary(forKey: deliveredDeadlinesKey)?[identifier]
            as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func recordDeadlineDelivery(_ notification: ScheduledUsageNotification) {
        var delivered = userDefaults.dictionary(forKey: deliveredDeadlinesKey) ?? [:]
        delivered[notification.identifier] = notification.deadlineDate.timeIntervalSince1970
        userDefaults.set(delivered, forKey: deliveredDeadlinesKey)
    }

    func observations() -> [UUID: CodexAccountUsage] {
        guard let data = userDefaults.data(forKey: observationsKey) else { return [:] }
        return (try? JSONDecoder().decode([UUID: CodexAccountUsage].self, from: data)) ?? [:]
    }

    func saveObservations(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) {
        let updatedObservations = UsageNotificationPlanner.observations(
            for: accounts,
            usageByAccountID: usageByAccountID
        )
        let activeIDs = Set(accounts.map(\.id))
        var allObservations = observations().filter { activeIDs.contains($0.key) }
        allObservations.merge(updatedObservations) { _, updated in updated }
        guard let data = try? JSONEncoder().encode(allObservations) else { return }
        userDefaults.set(data, forKey: observationsKey)
    }
}
