import Foundation

enum UsageDeadlineStyle: Equatable, Sendable {
    case fullDate
    case todayOrTomorrow
}

enum ScheduledUsageNotificationKind: Equatable, Sendable {
    case fiveHourReset
    case weeklyReset
    case bankedResetExpiry
}

struct ScheduledUsageNotification: Equatable, Sendable {
    let identifier: String
    let accountID: UUID
    let accountName: String
    let kind: ScheduledUsageNotificationKind
    let title: String
    let body: String
    let deadlineUpdateTitle: String
    let deadlineDescription: String
    let deadlineStyle: UsageDeadlineStyle
    let notificationDate: Date
    let deadlineDate: Date

    var sourceIdentifier: String {
        guard let range = identifier.range(of: "-deadline-update-", options: .backwards) else {
            return identifier
        }
        return String(identifier[..<range.lowerBound])
    }

    var isDeadlineUpdate: Bool {
        identifier.contains("-deadline-update-")
    }

    func deadlineUpdateNotification(at date: Date) -> ScheduledUsageNotification {
        ScheduledUsageNotification(
            identifier: "\(identifier)-deadline-update-\(Int(deadlineDate.timeIntervalSinceReferenceDate))",
            accountID: accountID,
            accountName: accountName,
            kind: kind,
            title: deadlineUpdateTitle,
            body: "\(deadlineDescription): \(UsageNotificationPlanner.formattedDeadline(deadlineDate, style: deadlineStyle, relativeTo: date)).",
            deadlineUpdateTitle: deadlineUpdateTitle,
            deadlineDescription: deadlineDescription,
            deadlineStyle: deadlineStyle,
            notificationDate: date,
            deadlineDate: deadlineDate
        )
    }
}

struct UsageObservation: Codable, Equatable, Sendable {
    let fiveHour: CodexUsageWindow?
    let weekly: CodexUsageWindow?
    let bankedResets: CodexBankedResetSummary?

    init(usage: CodexAccountUsage) {
        fiveHour = usage.fiveHour
        weekly = usage.weekly
        bankedResets = usage.bankedResets
    }
}

struct ImmediateUsageNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}
