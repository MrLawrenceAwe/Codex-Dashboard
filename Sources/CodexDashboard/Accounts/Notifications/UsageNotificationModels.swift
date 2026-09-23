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
    struct Window: Codable, Equatable, Sendable {
        let usedPercent: Int
        let resetsAt: Date?
    }

    let fiveHour: Window?
    let weekly: Window?
    let bankedResets: CodexBankedResetSummary?

    init(usage: CodexAccountUsage) {
        fiveHour = usage.fiveHour.map { Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        weekly = usage.weekly.map { Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        bankedResets = usage.bankedResets
    }
}

struct ImmediateUsageNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}
