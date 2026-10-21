import Foundation

typealias DeadlineUsageRefreshHandler = @MainActor @Sendable (UUID) async -> CodexAccountUsageSnapshot?

enum UsageDeadlineStyle: Equatable, Sendable {
    case fullDate
    case todayOrTomorrow
}

enum ScheduledUsageNotificationKind: String, CaseIterable, Hashable, Sendable {
    case fiveHourReset = "5-hour"
    case weeklyReset = "weekly"
    case bankedResetExpiry = "banked-reset-expiry"

    func deadline(in usage: CodexAccountUsage) -> Date? {
        switch self {
        case .fiveHourReset: usage.fiveHour?.resetsAt
        case .weeklyReset: usage.weekly?.resetsAt
        case .bankedResetExpiry: usage.bankedResets?.nextExpiration
        }
    }
}

struct ScheduledUsageNotification: Equatable, Sendable {
    let notificationID: UsageDeadlineNotificationID
    let accountName: String
    let title: String
    let body: String
    let deadlineUpdateTitle: String
    let deadlineDescription: String
    let deadlineStyle: UsageDeadlineStyle
    let notificationDate: Date
    let deadlineDate: Date

    var identifier: String { notificationID.rawValue }
    var accountID: UUID { notificationID.accountID }
    var kind: ScheduledUsageNotificationKind { notificationID.kind }
    var sourceIdentifier: String { notificationID.sourceIdentifier }
    var isDeadlineUpdate: Bool { notificationID.isDeadlineUpdate }

    func deadlineUpdateNotification(at date: Date) -> ScheduledUsageNotification {
        ScheduledUsageNotification(
            notificationID: notificationID.updatingDeadline(to: deadlineDate),
            accountName: accountName,
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

struct ImmediateUsageNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}
