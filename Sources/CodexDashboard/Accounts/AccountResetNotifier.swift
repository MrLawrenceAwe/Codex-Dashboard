import Foundation
import UserNotifications

struct AccountResetNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let notificationDate: Date
    let deadlineDate: Date
}

enum AccountResetNotificationPlanner {
    private static let oneHour: TimeInterval = 60 * 60
    private static let fiveHours: TimeInterval = 5 * 60 * 60
    private static let twentyFourHours: TimeInterval = 24 * 60 * 60

    static func notifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        now: Date = .now
    ) -> [AccountResetNotification] {
        deliverableNotifications(
            for: accounts,
            usageByAccountID: usageByAccountID,
            now: now
        ).filter { $0.notificationDate > now }
    }

    static func deliverableNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        now: Date = .now
    ) -> [AccountResetNotification] {
        accounts.flatMap { account -> [AccountResetNotification] in
            guard let usage = usageByAccountID[account.id]?.usage else { return [] }
            return limitNotifications(
                for: account,
                windowName: "5-hour",
                window: usage.fiveHour,
                leadTimes: [oneHour],
                now: now
            ) + limitNotifications(
                for: account,
                windowName: "Weekly",
                window: usage.weekly,
                leadTimes: [twentyFourHours, fiveHours, oneHour],
                now: now
            ) + bankedResetExpiryNotifications(for: account, resets: usage.bankedResets, now: now)
        }.sorted { $0.identifier < $1.identifier }
    }

    private static func limitNotifications(
        for account: SavedAccount,
        windowName: String,
        window: CodexUsageWindow?,
        leadTimes: [TimeInterval],
        now: Date
    ) -> [AccountResetNotification] {
        guard let window, let resetsAt = window.resetsAt else { return [] }
        guard resetsAt > now else { return [] }
        let remainingPercent = max(0, min(100, 100 - window.usedPercent))
        return leadTimes.map { leadTime in
            let leadTimeDescription = description(for: leadTime)
            return AccountResetNotification(
                identifier: "codex-dashboard-account-deadline-\(account.id.uuidString.lowercased())-\(windowName.lowercased())-\(identifierComponent(for: leadTime))",
                title: "Codex limit resets in \(leadTimeDescription)",
                body: "\(account.name)’s \(windowName) limit has \(remainingPercent)% remaining and will reset in \(leadTimeDescription).",
                notificationDate: resetsAt.addingTimeInterval(-leadTime),
                deadlineDate: resetsAt
            )
        }
    }

    private static func bankedResetExpiryNotifications(
        for account: SavedAccount,
        resets: CodexBankedResetSummary?,
        now: Date
    ) -> [AccountResetNotification] {
        guard let resets, resets.availableCount > 0, let expiration = resets.nextExpiration, expiration > now else {
            return []
        }
        return [twentyFourHours, fiveHours, oneHour].map { leadTime in
            let leadTimeDescription = description(for: leadTime)
            let countDescription = resets.availableCount == 1 ? "1 banked reset" : "\(resets.availableCount) banked resets"
            return AccountResetNotification(
                identifier: "codex-dashboard-account-deadline-\(account.id.uuidString.lowercased())-banked-reset-expiry-\(identifierComponent(for: leadTime))",
                title: "Banked Codex reset expires in \(leadTimeDescription)",
                body: "\(account.name) has \(countDescription) available; the next one expires in \(leadTimeDescription).",
                notificationDate: expiration.addingTimeInterval(-leadTime),
                deadlineDate: expiration
            )
        }
    }

    private static func description(for leadTime: TimeInterval) -> String {
        switch leadTime {
        case twentyFourHours: "24 hours"
        case fiveHours: "5 hours"
        default: "one hour"
        }
    }

    private static func identifierComponent(for leadTime: TimeInterval) -> String {
        "\(Int(leadTime / 60 / 60))h"
    }
}

@MainActor
protocol AccountResetNotifying {
    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async
}

@MainActor
struct NoopAccountResetNotifier: AccountResetNotifying {
    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {}
}

@MainActor
final class AccountResetNotifier: AccountResetNotifying {
    private static let identifierPrefix = "codex-dashboard-account-deadline-"

    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {
        let notifications = AccountResetNotificationPlanner.notifications(
            for: accounts,
            usageByAccountID: usageByAccountID
        )
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        let existingIdentifiers = pendingRequests.compactMap { request in
            request.identifier.hasPrefix(Self.identifierPrefix) ? request.identifier : nil
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: existingIdentifiers)

        guard !notifications.isEmpty, await notificationsAreAuthorized() else { return }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
                    from: notification.notificationDate
                ),
                repeats: false
            )
            try? await notificationCenter.add(
                UNNotificationRequest(
                    identifier: notification.identifier,
                    content: content,
                    trigger: trigger
                )
            )
        }
    }

    private func notificationsAreAuthorized() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
