import Foundation

enum UsageDeadlineStyle: Equatable, Sendable {
    case fullDate
    case todayOrTomorrow
}

struct ScheduledUsageNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let deadlineUpdateTitle: String
    let deadlineDescription: String
    let deadlineStyle: UsageDeadlineStyle
    let usageSummary: String
    let notificationDate: Date
    let deadlineDate: Date

    var sourceIdentifier: String {
        guard let range = identifier.range(of: "-deadline-update-", options: .backwards) else {
            return identifier
        }
        return String(identifier[..<range.lowerBound])
    }

    func deadlineUpdateNotification(at date: Date) -> ScheduledUsageNotification {
        ScheduledUsageNotification(
            identifier: "\(identifier)-deadline-update-\(Int(deadlineDate.timeIntervalSinceReferenceDate))",
            title: deadlineUpdateTitle,
            body: "\(deadlineDescription): \(UsageNotificationPlanner.formattedDeadline(deadlineDate, style: deadlineStyle, relativeTo: date)).\n\(usageSummary)",
            deadlineUpdateTitle: deadlineUpdateTitle,
            deadlineDescription: deadlineDescription,
            deadlineStyle: deadlineStyle,
            usageSummary: usageSummary,
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

    init(usage: CodexAccountUsage) {
        fiveHour = usage.fiveHour.map { Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        weekly = usage.weekly.map { Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
    }
}

struct ImmediateUsageNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}

