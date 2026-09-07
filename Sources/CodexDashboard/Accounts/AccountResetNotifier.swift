import Foundation
import UserNotifications

struct AccountResetNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let deadlineDescription: String
    let usageSummary: String
    let notificationDate: Date
    let deadlineDate: Date

    var sourceIdentifier: String {
        guard let range = identifier.range(of: "-deadline-update-", options: .backwards) else {
            return identifier
        }
        return String(identifier[..<range.lowerBound])
    }

    func deadlineUpdateNotification(at date: Date) -> AccountResetNotification {
        AccountResetNotification(
            identifier: "\(identifier)-deadline-update-\(Int(deadlineDate.timeIntervalSinceReferenceDate))",
            title: "\(title) time updated",
            body: "\(deadlineDescription) at \(AccountResetNotificationPlanner.formattedDeadline(deadlineDate)). \(usageSummary)",
            deadlineDescription: deadlineDescription,
            usageSummary: usageSummary,
            notificationDate: date,
            deadlineDate: deadlineDate
        )
    }
}

enum AccountResetNotificationPlanner {
    private static let oneHour: TimeInterval = 60 * 60
    private static let fiveHours: TimeInterval = 5 * 60 * 60
    private static let twelveHours: TimeInterval = 12 * 60 * 60
    private static let twentyFourHours: TimeInterval = 24 * 60 * 60
    private static let thirtySixHours: TimeInterval = 36 * 60 * 60
    private static let fortyEightHours: TimeInterval = 48 * 60 * 60
    private static let seventyTwoHours: TimeInterval = 72 * 60 * 60
    private static let extendedLeadTimes = [
        seventyTwoHours,
        fortyEightHours,
        thirtySixHours,
        twentyFourHours,
        twelveHours,
        fiveHours,
        oneHour,
    ]

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
                usageSummary: usageSummary(for: usage),
                now: now
            ) + limitNotifications(
                for: account,
                windowName: "Weekly",
                window: usage.weekly,
                leadTimes: extendedLeadTimes,
                usageSummary: usageSummary(for: usage),
                now: now
            ) + bankedResetExpiryNotifications(
                for: account,
                resets: usage.bankedResets,
                usageSummary: usageSummary(for: usage),
                now: now
            )
        }.sorted { $0.identifier < $1.identifier }
    }

    static func deadlineUpdateNotifications(
        from notifications: [AccountResetNotification],
        previousDeadlines: [String: Date],
        sentUpdates: [String: Date],
        now: Date
    ) -> [AccountResetNotification] {
        notifications.compactMap { notification in
            guard let previousDeadline = previousDeadlines[notification.identifier],
                  previousDeadline != notification.deadlineDate,
                  notification.notificationDate <= now,
                  sentUpdates[notification.sourceIdentifier] != notification.deadlineDate
            else { return nil }
            return notification.deadlineUpdateNotification(at: now.addingTimeInterval(1))
        }
    }

    private static func limitNotifications(
        for account: SavedAccount,
        windowName: String,
        window: CodexUsageWindow?,
        leadTimes: [TimeInterval],
        usageSummary: String,
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
                body: "\(account.name)’s \(windowName) limit has \(remainingPercent)% remaining and will reset in \(leadTimeDescription), at \(formattedDeadline(resetsAt)). \(usageSummary)",
                deadlineDescription: "\(account.name)’s \(windowName) limit will reset",
                usageSummary: usageSummary,
                notificationDate: resetsAt.addingTimeInterval(-leadTime),
                deadlineDate: resetsAt
            )
        }
    }

    private static func bankedResetExpiryNotifications(
        for account: SavedAccount,
        resets: CodexBankedResetSummary?,
        usageSummary: String,
        now: Date
    ) -> [AccountResetNotification] {
        guard let resets, resets.availableCount > 0, let expiration = resets.nextExpiration, expiration > now else {
            return []
        }
        return extendedLeadTimes.map { leadTime in
            let leadTimeDescription = description(for: leadTime)
            let countDescription = resets.availableCount == 1 ? "1 banked reset" : "\(resets.availableCount) banked resets"
            return AccountResetNotification(
                identifier: "codex-dashboard-account-deadline-\(account.id.uuidString.lowercased())-banked-reset-expiry-\(identifierComponent(for: leadTime))",
                title: "Banked Codex reset expires in \(leadTimeDescription)",
                body: "\(account.name) has \(countDescription) available; the next one expires in \(leadTimeDescription), at \(formattedDeadline(expiration)). \(usageSummary)",
                deadlineDescription: "\(account.name)’s next banked reset will expire",
                usageSummary: usageSummary,
                notificationDate: expiration.addingTimeInterval(-leadTime),
                deadlineDate: expiration
            )
        }
    }

    private static func description(for leadTime: TimeInterval) -> String {
        switch leadTime {
        case seventyTwoHours: "72 hours"
        case fortyEightHours: "48 hours"
        case thirtySixHours: "36 hours"
        case twentyFourHours: "24 hours"
        case twelveHours: "12 hours"
        case fiveHours: "5 hours"
        default: "one hour"
        }
    }

    private static func identifierComponent(for leadTime: TimeInterval) -> String {
        "\(Int(leadTime / 60 / 60))h"
    }

    private static func usageSummary(for usage: CodexAccountUsage) -> String {
        let fiveHour = remainingUsage(for: usage.fiveHour)
        let weekly = remainingUsage(for: usage.weekly)
        let bankedResets = usage.bankedResets.map { String(max(0, $0.availableCount)) } ?? "unavailable"
        return "Usage remaining: 5-hour \(fiveHour) · weekly \(weekly) · banked resets \(bankedResets)."
    }

    private static func remainingUsage(for window: CodexUsageWindow?) -> String {
        guard let window else { return "unavailable" }
        return "\(max(0, min(100, 100 - window.usedPercent)))%"
    }

    static func formattedDeadline(_ deadline: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: deadline)
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
    private static let knownDeadlinesKey = "accountResetNotificationKnownDeadlines"
    private static let sentDeadlineUpdatesKey = "accountResetNotificationSentDeadlineUpdates"

    private let notificationCenter: UNUserNotificationCenter
    private let userDefaults: UserDefaults

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        userDefaults: UserDefaults = .standard
    ) {
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
    }

    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {
        let allNotifications = AccountResetNotificationPlanner.deliverableNotifications(
            for: accounts,
            usageByAccountID: usageByAccountID
        )
        let notifications = allNotifications.filter { $0.notificationDate > .now }
        let deadlineUpdates = AccountResetNotificationPlanner.deadlineUpdateNotifications(
            from: allNotifications,
            previousDeadlines: deadlines(forKey: Self.knownDeadlinesKey),
            sentUpdates: deadlines(forKey: Self.sentDeadlineUpdatesKey),
            now: .now
        )
        let updateSources = Set(deadlineUpdates.map(\.sourceIdentifier))
        saveDeadlines(
            allNotifications.filter { !updateSources.contains($0.sourceIdentifier) },
            forKey: Self.knownDeadlinesKey
        )
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        let existingIdentifiers = pendingRequests.compactMap { request in
            request.identifier.hasPrefix(Self.identifierPrefix) ? request.identifier : nil
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: existingIdentifiers)

        let requests = notifications + deadlineUpdates
        guard !requests.isEmpty, await notificationsAreAuthorized() else { return }
        for notification in requests {
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
            do {
                try await notificationCenter.add(
                    UNNotificationRequest(
                        identifier: notification.identifier,
                        content: content,
                        trigger: trigger
                    )
                )
                if notification.identifier.contains("-deadline-update-") {
                    saveDeadlines([notification], forKey: Self.knownDeadlinesKey)
                    saveDeadlines([notification], forKey: Self.sentDeadlineUpdatesKey)
                }
            } catch {
                // Keep the previous deadline so a later refresh can retry an
                // immediate revised-deadline alert that macOS rejected.
            }
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

    private func deadlines(forKey key: String) -> [String: Date] {
        guard let rawValues = userDefaults.dictionary(forKey: key) else { return [:] }
        return rawValues.reduce(into: [:]) { result, item in
            guard let timestamp = item.value as? Double else { return }
            result[item.key] = Date(timeIntervalSinceReferenceDate: timestamp)
        }
    }

    private func saveDeadlines(_ notifications: [AccountResetNotification], forKey key: String) {
        guard !notifications.isEmpty else { return }
        var values = userDefaults.dictionary(forKey: key) ?? [:]
        for notification in notifications {
            values[notification.sourceIdentifier] = notification.deadlineDate.timeIntervalSinceReferenceDate
        }
        userDefaults.set(values, forKey: key)
    }
}
