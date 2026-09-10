import Foundation
import UserNotifications

enum AccountResetDeadlineStyle: Equatable, Sendable {
    case fullDate
    case todayOrTomorrow
}

struct AccountResetNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let deadlineUpdateTitle: String
    let deadlineDescription: String
    let deadlineStyle: AccountResetDeadlineStyle
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
            title: deadlineUpdateTitle,
            body: "\(deadlineDescription): \(AccountResetNotificationPlanner.formattedDeadline(deadlineDate, style: deadlineStyle, relativeTo: date)).\n\(usageSummary)",
            deadlineUpdateTitle: deadlineUpdateTitle,
            deadlineDescription: deadlineDescription,
            deadlineStyle: deadlineStyle,
            usageSummary: usageSummary,
            notificationDate: date,
            deadlineDate: deadlineDate
        )
    }
}

struct AccountUsageResetObservation: Codable, Equatable, Sendable {
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

struct AccountLimitResetNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}

enum AccountResetNotificationPlanner {
    private static let resetTimeCorrectionTolerance: TimeInterval = 5 * 60
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
            let fiveHourNotifications = usage.weekly?.usedPercent == 0 ? [] : limitNotifications(
                for: account,
                windowName: "5-hour",
                window: usage.fiveHour,
                leadTimes: [oneHour],
                usageSummary: usageSummary(for: usage),
                now: now
            )
            return fiveHourNotifications + limitNotifications(
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

    static func resetNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        previousObservations: [UUID: AccountUsageResetObservation],
        now: Date = .now
    ) -> [AccountLimitResetNotification] {
        accounts.flatMap { account -> [AccountLimitResetNotification] in
            guard let usage = usageByAccountID[account.id]?.usage,
                  let previous = previousObservations[account.id]
            else { return [] }
            return [
                resetNotification(
                    for: account,
                    windowName: "5-hour",
                    current: usage.fiveHour,
                    previous: previous.fiveHour,
                    usageSummary: usageSummary(for: usage),
                    now: now
                ),
                resetNotification(
                    for: account,
                    windowName: "Weekly",
                    current: usage.weekly,
                    previous: previous.weekly,
                    usageSummary: usageSummary(for: usage),
                    now: now
                ),
            ].compactMap { $0 }
        }.sorted { $0.identifier < $1.identifier }
    }

    /// Produces one immediate alert as each usage window passes a remaining-usage threshold.
    /// Comparing observations from the same reset window makes the alert naturally fire only
    /// once, including after the dashboard is relaunched.
    static func usageThresholdNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        previousObservations: [UUID: AccountUsageResetObservation],
        now: Date = .now
    ) -> [AccountLimitResetNotification] {
        accounts.flatMap { account -> [AccountLimitResetNotification] in
            guard let usage = usageByAccountID[account.id]?.usage,
                  let previous = previousObservations[account.id]
            else { return [] }
            return [
                thresholdNotifications(
                    for: account,
                    windowName: "5-hour",
                    current: usage.fiveHour,
                    previous: previous.fiveHour,
                    usageSummary: usageSummary(for: usage),
                    now: now
                ),
                thresholdNotifications(
                    for: account,
                    windowName: "Weekly",
                    current: usage.weekly,
                    previous: previous.weekly,
                    usageSummary: usageSummary(for: usage),
                    now: now
                ),
            ].flatMap { $0 }
        }.sorted { $0.identifier < $1.identifier }
    }

    static func observations(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) -> [UUID: AccountUsageResetObservation] {
        Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            usageByAccountID[account.id].map { (account.id, AccountUsageResetObservation(usage: $0.usage)) }
        })
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
            let notificationDate = resetsAt.addingTimeInterval(-leadTime)
            let deadlineStyle = deadlineStyle(for: windowName)
            return AccountResetNotification(
                identifier: "codex-dashboard-account-deadline-\(account.id.uuidString.lowercased())-\(windowName.lowercased())-\(identifierComponent(for: leadTime))",
                title: "Codex limit resets in \(leadTimeDescription)",
                body: "\(account.name)’s \(windowName): \(remainingPercent)% left · resets \(formattedDeadline(resetsAt, style: deadlineStyle, relativeTo: notificationDate)).\n\(usageSummary)",
                deadlineUpdateTitle: "\(windowName) reset time changed",
                deadlineDescription: "\(account.name)’s \(windowName) reset moved",
                deadlineStyle: deadlineStyle,
                usageSummary: usageSummary,
                notificationDate: notificationDate,
                deadlineDate: resetsAt
            )
        }
    }

    private static func resetNotification(
        for account: SavedAccount,
        windowName: String,
        current: CodexUsageWindow?,
        previous: AccountUsageResetObservation.Window?,
        usageSummary: String,
        now: Date
    ) -> AccountLimitResetNotification? {
        guard let current, let previous,
              let previousReset = previous.resetsAt,
              let nextReset = current.resetsAt,
              nextReset > previousReset
        else { return nil }

        let previousAllowance = max(0, min(100, 100 - previous.usedPercent))
        let currentAllowance = max(0, min(100, 100 - current.usedPercent))
        let nextResetDescription = formattedDeadline(nextReset, style: deadlineStyle(for: windowName), relativeTo: now)
        let identifier = "codex-dashboard-account-limit-reset-\(account.id.uuidString.lowercased())-\(windowName.lowercased())-\(Int(previousReset.timeIntervalSinceReferenceDate))"
        if previousReset > now {
            guard previous.usedPercent > current.usedPercent else { return nil }
            return AccountLimitResetNotification(
                identifier: identifier,
                title: "Codex limit reset early",
                body: "\(account.name)’s \(windowName): \(previousAllowance)% → \(currentAllowance)% early · next \(nextResetDescription).\n\(usageSummary)"
            )
        }
        return AccountLimitResetNotification(
            identifier: identifier,
            title: "Codex limit reset",
            body: "\(account.name)’s \(windowName) reset: \(currentAllowance)% left · next \(nextResetDescription).\n\(usageSummary)"
        )
    }

    private static func thresholdNotifications(
        for account: SavedAccount,
        windowName: String,
        current: CodexUsageWindow?,
        previous: AccountUsageResetObservation.Window?,
        usageSummary: String,
        now: Date
    ) -> [AccountLimitResetNotification] {
        guard let current, let previous,
              let reset = current.resetsAt,
              let previousReset = previous.resetsAt,
              abs(previousReset.timeIntervalSince(reset)) <= resetTimeCorrectionTolerance
        else { return [] }

        let currentRemaining = max(0, min(100, 100 - current.usedPercent))
        let previousRemaining = max(0, min(100, 100 - previous.usedPercent))
        return [80, 50, 20].compactMap { threshold in
            guard previousRemaining >= threshold, currentRemaining < threshold else { return nil }
            return AccountLimitResetNotification(
                identifier: "codex-dashboard-account-usage-threshold-\(account.id.uuidString.lowercased())-\(windowName.lowercased())-\(threshold)-\(Int(previousReset.timeIntervalSinceReferenceDate))",
                title: "Codex \(windowName) usage below \(threshold)%",
                body: "\(account.name)’s \(windowName): \(currentRemaining)% left · resets \(formattedDeadline(reset, style: deadlineStyle(for: windowName), relativeTo: now)).\n\(usageSummary)"
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
                body: "\(account.name): \(countDescription) · next expires \(formattedDeadline(expiration)).\n\(usageSummary)",
                deadlineUpdateTitle: "Banked reset expiry changed",
                deadlineDescription: "\(account.name)’s next banked reset will now expire",
                deadlineStyle: .fullDate,
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
        return "⏱ 5-hour \(fiveHour) · 📅 Weekly \(weekly) · 🎟 Banked \(bankedResets)"
    }

    private static func remainingUsage(for window: CodexUsageWindow?) -> String {
        guard let window else { return "unavailable" }
        return "\(max(0, min(100, 100 - window.usedPercent)))%"
    }

    private static func deadlineStyle(for windowName: String) -> AccountResetDeadlineStyle {
        windowName == "5-hour" ? .todayOrTomorrow : .fullDate
    }

    static func formattedDeadline(
        _ deadline: Date,
        style: AccountResetDeadlineStyle,
        relativeTo referenceDate: Date
    ) -> String {
        guard style == .todayOrTomorrow else { return formattedDeadline(deadline) }
        let calendar = Calendar.current
        let day = calendar.isDate(deadline, inSameDayAs: referenceDate) ? "today" : "tomorrow"
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(day) at \(formatter.string(from: deadline))"
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
    private static let usageObservationsKey = "accountResetNotificationUsageObservations"

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
        let resetNotifications = AccountResetNotificationPlanner.resetNotifications(
            for: accounts,
            usageByAccountID: usageByAccountID,
            previousObservations: observations(),
            now: .now
        )
        let thresholdNotifications = AccountResetNotificationPlanner.usageThresholdNotifications(
            for: accounts,
            usageByAccountID: usageByAccountID,
            previousObservations: observations()
        )
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
        let immediateNotifications = resetNotifications + thresholdNotifications
        guard !requests.isEmpty || !immediateNotifications.isEmpty, await notificationsAreAuthorized() else {
            saveObservations(for: accounts, usageByAccountID: usageByAccountID)
            return
        }
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
        for notification in immediateNotifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            try? await notificationCenter.add(
                UNNotificationRequest(
                    identifier: notification.identifier,
                    content: content,
                    trigger: nil
                )
            )
        }
        saveObservations(for: accounts, usageByAccountID: usageByAccountID)
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

    private func observations() -> [UUID: AccountUsageResetObservation] {
        guard let data = userDefaults.data(forKey: Self.usageObservationsKey) else { return [:] }
        return (try? JSONDecoder().decode([UUID: AccountUsageResetObservation].self, from: data)) ?? [:]
    }

    private func saveObservations(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) {
        let updatedObservations = AccountResetNotificationPlanner.observations(
            for: accounts,
            usageByAccountID: usageByAccountID
        )
        var allObservations = observations()
        allObservations.merge(updatedObservations) { _, updated in updated }
        guard let data = try? JSONEncoder().encode(allObservations) else { return }
        userDefaults.set(data, forKey: Self.usageObservationsKey)
    }
}
