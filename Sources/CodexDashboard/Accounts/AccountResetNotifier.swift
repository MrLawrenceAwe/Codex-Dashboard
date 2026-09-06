import Foundation
import UserNotifications

struct AccountResetNotification: Equatable, Sendable {
    let identifier: String
    let accountName: String
    let windowName: String
    let remainingPercent: Int
    let notificationDate: Date
    let resetDate: Date
}

enum AccountResetNotificationPlanner {
    static let notificationLeadTime: TimeInterval = 60 * 60

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
            return [
                notification(for: account, windowName: "5-hour", window: usage.fiveHour, now: now),
                notification(for: account, windowName: "Weekly", window: usage.weekly, now: now),
            ].compactMap { $0 }
        }.sorted { $0.identifier < $1.identifier }
    }

    private static func notification(
        for account: SavedAccount,
        windowName: String,
        window: CodexUsageWindow?,
        now: Date
    ) -> AccountResetNotification? {
        guard let window, let resetsAt = window.resetsAt else { return nil }
        guard resetsAt > now else { return nil }
        let notificationDate = resetsAt.addingTimeInterval(-notificationLeadTime)
        return AccountResetNotification(
            identifier: "codex-dashboard-account-reset-\(account.id.uuidString.lowercased())-\(windowName.lowercased())",
            accountName: account.name,
            windowName: windowName,
            remainingPercent: max(0, min(100, 100 - window.usedPercent)),
            notificationDate: notificationDate,
            resetDate: resetsAt
        )
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
    private static let identifierPrefix = "codex-dashboard-account-reset-"

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
            content.title = "Codex limit resets in one hour"
            content.body = "\(notification.accountName)’s \(notification.windowName) limit has \(notification.remainingPercent)% remaining and will reset in one hour."
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
