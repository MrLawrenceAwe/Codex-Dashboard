import Foundation

/// Keeps persisted delivery/history keys stable while giving their parts one owner.
struct UsageDeadlineNotificationID: Equatable, Sendable {
    struct Group: Hashable, Sendable {
        let accountID: UUID
        let kind: ScheduledUsageNotificationKind
    }

    let accountID: UUID
    let kind: ScheduledUsageNotificationKind
    let leadTimeHours: Int
    var updateTimestamp: Int? = nil
    var refreshTimestamp: Int? = nil

    var group: Group { Group(accountID: accountID, kind: kind) }
    var isDeadlineUpdate: Bool { updateTimestamp != nil }

    var sourceIdentifier: String {
        "codex-dashboard-account-deadline-v2-\(accountID.uuidString.lowercased())-\(kind.rawValue)-\(leadTimeHours)h"
    }

    var deliveryIdentifier: String {
        sourceIdentifier + (updateTimestamp.map { "-deadline-update-\($0)" } ?? "")
    }

    var rawValue: String {
        deliveryIdentifier + (refreshTimestamp.map { "-fresh-\($0)" } ?? "")
    }

    func updatingDeadline(to date: Date) -> Self {
        var updated = self
        updated.updateTimestamp = Int(date.timeIntervalSinceReferenceDate)
        return updated
    }

    func refreshed(at date: Date) -> Self {
        var refreshed = self
        refreshed.refreshTimestamp = Int(date.timeIntervalSince1970)
        return refreshed
    }

    static func isDeadlineIdentifier(_ value: String) -> Bool {
        // Include previously scheduled versions so macOS pending requests are cleared.
        value.hasPrefix("codex-dashboard-account-deadline-")
    }

    init(accountID: UUID, kind: ScheduledUsageNotificationKind, leadTimeHours: Int) {
        self.accountID = accountID
        self.kind = kind
        self.leadTimeHours = leadTimeHours
    }

    init?(rawValue: String) {
        let prefix = "codex-dashboard-account-deadline-v2-"
        guard rawValue.hasPrefix(prefix) else { return nil }
        let suffix = String(rawValue.dropFirst(prefix.count))
        guard let accountID = UUID(uuidString: String(suffix.prefix(36))),
              suffix.dropFirst(36).first == "-" else { return nil }
        let kindAndTime = String(suffix.dropFirst(37))
        guard let kind = ScheduledUsageNotificationKind.allCases.first(where: {
            kindAndTime.hasPrefix($0.rawValue + "-")
        }) else { return nil }
        let time = String(kindAndTime.dropFirst(kind.rawValue.count + 1))
        let refreshParts = time.components(separatedBy: "-fresh-")
        guard refreshParts.count <= 2 else { return nil }
        let updateParts = refreshParts[0].components(separatedBy: "-deadline-update-")
        guard updateParts.count <= 2,
              updateParts[0].hasSuffix("h"),
              let hours = Int(updateParts[0].dropLast()), hours > 0 else { return nil }
        self.init(accountID: accountID, kind: kind, leadTimeHours: hours)
        if updateParts.count == 2 {
            guard let timestamp = Int(updateParts[1]) else { return nil }
            updateTimestamp = timestamp
        }
        if refreshParts.count == 2 {
            guard let timestamp = Int(refreshParts[1]) else { return nil }
            refreshTimestamp = timestamp
        }
    }
}
