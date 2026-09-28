import Foundation

enum UsageNotificationPlanner {
    private static let resetTimeCorrectionTolerance: TimeInterval = 5 * 60
    private static let oneHour: TimeInterval = 60 * 60
    private static let extendedLeadTimes: [TimeInterval] = [72, 48, 36, 24, 12, 5, 1]
        .map { $0 * oneHour }

    private enum UsageWindowKind {
        case fiveHour, weekly

        var displayName: String { self == .fiveHour ? "5-hour" : "Weekly" }
        var identifier: String { self == .fiveHour ? "5-hour" : "weekly" }
        var duration: TimeInterval { self == .fiveHour ? 5 * 60 * 60 : 7 * 24 * 60 * 60 }
        var deadlineStyle: UsageDeadlineStyle { self == .fiveHour ? .todayOrTomorrow : .fullDate }
        var notificationKind: ScheduledUsageNotificationKind {
            self == .fiveHour ? .fiveHourReset : .weeklyReset
        }
        var leadTimes: [TimeInterval] {
            self == .fiveHour ? [UsageNotificationPlanner.oneHour] : UsageNotificationPlanner.extendedLeadTimes
        }
        var thresholds: [Int] { self == .fiveHour ? [50, 20] : [80, 50, 20] }
        func window(in usage: CodexAccountUsage) -> CodexUsageWindow? {
            self == .fiveHour ? usage.fiveHour : usage.weekly
        }
        func window(in observation: UsageObservation) -> CodexUsageWindow? {
            self == .fiveHour ? observation.fiveHour : observation.weekly
        }
    }

    private static let windowKinds: [UsageWindowKind] = [.fiveHour, .weekly]

    struct Plan {
        let scheduled: [ScheduledUsageNotification]
        let immediate: [ImmediateUsageNotification]
        let deadlinesWithoutUpdateAlerts: [ScheduledUsageNotification]
    }

    static func plan(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        previousObservations: [UUID: UsageObservation],
        previousDeadlines: [String: Date],
        sentUpdates: [String: Date],
        now: Date
    ) -> Plan {
        let all = deliverableNotifications(for: accounts, usageByAccountID: usageByAccountID, now: now)
        let updates = deadlineUpdateNotifications(
            from: all, previousDeadlines: previousDeadlines, sentUpdates: sentUpdates, now: now
        )
        let updateSources = Set(updates.map(\.sourceIdentifier))
        return Plan(
            scheduled: all.filter { $0.notificationDate > now } + updates,
            immediate: bankedResetNotifications(
                for: accounts, usageByAccountID: usageByAccountID,
                previousObservations: previousObservations
            ) + resetNotifications(
                for: accounts, usageByAccountID: usageByAccountID,
                previousObservations: previousObservations, now: now
            ) + usageThresholdNotifications(
                for: accounts, usageByAccountID: usageByAccountID,
                previousObservations: previousObservations, now: now
            ),
            deadlinesWithoutUpdateAlerts: all.filter { !updateSources.contains($0.sourceIdentifier) }
        )
    }

    static func deliverableNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        now: Date = .now
    ) -> [ScheduledUsageNotification] {
        accounts.flatMap { account -> [ScheduledUsageNotification] in
            guard let usage = usageByAccountID[account.id]?.usage else { return [] }
            let limitReminders = hasWeeklyUsageRemaining(usage)
                ? windowKinds.flatMap { kind in
                    kind == .fiveHour && !hasFiveHourUsageRemaining(usage) ? [] : limitNotifications(
                        for: account,
                        windowKind: kind,
                        window: kind.window(in: usage),
                        leadTimes: kind.leadTimes,
                        now: now
                    )
                } : []
            return limitReminders + bankedResetExpiryNotifications(
                for: account,
                resets: usage.bankedResets,
                now: now
            )
        }.sorted { $0.identifier < $1.identifier }
    }

    static func deadlineUpdateNotifications(
        from notifications: [ScheduledUsageNotification],
        previousDeadlines: [String: Date],
        sentUpdates: [String: Date],
        now: Date
    ) -> [ScheduledUsageNotification] {
        let deliveredUpdateResetIdentifiers = Set<String>(notifications.compactMap { notification -> String? in
            guard let sentDeadline = sentUpdates[notification.sourceIdentifier],
                  !deadlinesDifferMeaningfully(sentDeadline, notification.deadlineDate)
            else { return nil }
            return resetIdentifier(for: notification)
        })
        let candidates = notifications.compactMap { notification -> ScheduledUsageNotification? in
            guard let previousDeadline = previousDeadlines[notification.identifier],
                  deadlinesDifferMeaningfully(previousDeadline, notification.deadlineDate),
                  notification.notificationDate <= now,
                  !deliveredUpdateResetIdentifiers.contains(resetIdentifier(for: notification))
            else { return nil }
            return notification
        }
        let latestMissedWarningByReset = Dictionary(grouping: candidates, by: resetIdentifier)
            .compactMapValues { warnings in warnings.max { $0.notificationDate < $1.notificationDate } }
        return latestMissedWarningByReset.values
            .map { $0.deadlineUpdateNotification(at: now.addingTimeInterval(1)) }
            .sorted { $0.identifier < $1.identifier }
    }

    private static func resetIdentifier(for notification: ScheduledUsageNotification) -> String {
        guard let separator = notification.identifier.lastIndex(of: "-") else {
            return notification.identifier
        }
        return String(notification.identifier[..<separator])
    }

    static func deadlinesDifferMeaningfully(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) > resetTimeCorrectionTolerance
    }

    static func resetNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        previousObservations: [UUID: UsageObservation],
        now: Date = .now
    ) -> [ImmediateUsageNotification] {
        accounts.flatMap { account -> [ImmediateUsageNotification] in
            guard let usage = usageByAccountID[account.id]?.usage,
                  hasWeeklyUsageRemaining(usage),
                  let previous = previousObservations[account.id]
            else { return [] }
            return windowKinds.compactMap { kind in
                resetNotification(
                    for: account,
                    windowKind: kind,
                    current: kind.window(in: usage),
                    previous: kind.window(in: previous),
                    usageSummary: usageSummary(for: usage),
                    now: now
                )
            }
        }.sorted { $0.identifier < $1.identifier }
    }

    static func bankedResetNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        previousObservations: [UUID: UsageObservation]
    ) -> [ImmediateUsageNotification] {
        accounts.compactMap { account in
            guard let snapshot = usageByAccountID[account.id],
                  let current = snapshot.usage.bankedResets,
                  let previous = previousObservations[account.id]?.bankedResets,
                  current.availableCount > previous.availableCount
            else { return nil }

            let added = current.availableCount - previous.availableCount
            let total = current.availableCount
            let expiration = current.nextExpiration.map {
                " · next expires \(formattedDeadline($0))"
            } ?? ""
            return ImmediateUsageNotification(
                identifier: "codex-dashboard-account-banked-resets-added-\(account.id.uuidString.lowercased())-\(Int(snapshot.fetchedAt.timeIntervalSince1970))-\(total)",
                title: added == 1 ? "Banked Codex reset added" : "\(added) banked Codex resets added",
                body: "\(account.name): \(total) banked \(total == 1 ? "reset" : "resets") available\(expiration)."
            )
        }.sorted { $0.identifier < $1.identifier }
    }

    /// Produces one immediate alert as each usage window passes a remaining-usage threshold.
    /// Comparing observations from the same reset window makes the alert naturally fire only
    /// once, including after the dashboard is relaunched.
    static func usageThresholdNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot],
        previousObservations: [UUID: UsageObservation],
        now: Date = .now
    ) -> [ImmediateUsageNotification] {
        accounts.flatMap { account -> [ImmediateUsageNotification] in
            guard let usage = usageByAccountID[account.id]?.usage,
                  hasWeeklyUsageRemaining(usage),
                  let previous = previousObservations[account.id]
            else { return [] }
            return windowKinds.flatMap { kind in
                thresholdNotifications(
                    for: account,
                    windowKind: kind,
                    current: kind.window(in: usage),
                    previous: kind.window(in: previous),
                    thresholds: kind.thresholds,
                    usageSummary: usageSummary(for: usage),
                    now: now
                )
            }
        }.sorted { $0.identifier < $1.identifier }
    }

    static func observations(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) -> [UUID: UsageObservation] {
        Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            usageByAccountID[account.id].map { (account.id, UsageObservation(usage: $0.usage)) }
        })
    }

    private static func limitNotifications(
        for account: SavedAccount,
        windowKind: UsageWindowKind,
        window: CodexUsageWindow?,
        leadTimes: [TimeInterval],
        now: Date
    ) -> [ScheduledUsageNotification] {
        guard let window, let resetsAt = window.resetsAt else { return [] }
        guard resetsAt > now else { return [] }
        return leadTimes.map { leadTime in
            let leadTimeDescription = description(for: leadTime)
            let notificationDate = resetsAt.addingTimeInterval(-leadTime)
            let deadlineStyle = windowKind.deadlineStyle
            return ScheduledUsageNotification(
                identifier: "codex-dashboard-account-deadline-v2-\(account.id.uuidString.lowercased())-\(windowKind.identifier)-\(identifierComponent(for: leadTime))",
                accountID: account.id,
                accountName: account.name,
                kind: windowKind.notificationKind,
                title: "Codex \(windowKind.displayName.lowercased()) usage resets in \(leadTimeDescription)",
                body: "\(account.name)’s \(windowKind.displayName) usage resets \(formattedDeadline(resetsAt, style: deadlineStyle, relativeTo: notificationDate)).",
                deadlineUpdateTitle: "\(windowKind.displayName) reset time changed",
                deadlineDescription: "\(account.name)’s \(windowKind.displayName) reset moved",
                deadlineStyle: deadlineStyle,
                notificationDate: notificationDate,
                deadlineDate: resetsAt
            )
        }
    }

    private static func resetNotification(
        for account: SavedAccount,
        windowKind: UsageWindowKind,
        current: CodexUsageWindow?,
        previous: CodexUsageWindow?,
        usageSummary: String,
        now: Date
    ) -> ImmediateUsageNotification? {
        guard let current, let previous,
              let previousReset = previous.resetsAt,
              let nextReset = current.resetsAt,
              nextReset > previousReset
        else { return nil }

        let previousAllowance = max(0, min(100, 100 - previous.usedPercent))
        let currentAllowance = max(0, min(100, 100 - current.usedPercent))
        let nextResetDescription = formattedDeadline(nextReset, style: windowKind.deadlineStyle, relativeTo: now)
        let identifier = "codex-dashboard-account-limit-reset-\(account.id.uuidString.lowercased())-\(windowKind.identifier)-\(Int(previousReset.timeIntervalSinceReferenceDate))"
        // Usage can rise quickly after a real reset. A full new window is still
        // evidence of a reset, while a revised deadline alone is not.
        let windowDuration = windowKind.duration
        let observedNewWindow = abs(nextReset.timeIntervalSince(previousReset) - windowDuration)
            <= resetTimeCorrectionTolerance
        guard previous.usedPercent > current.usedPercent || (previousReset <= now && observedNewWindow)
        else { return nil }
        if previousReset > now {
            return ImmediateUsageNotification(
                identifier: identifier,
                title: "Codex \(windowKind.displayName.lowercased()) usage reset early",
                body: "\(account.name)’s \(windowKind.displayName): \(previousAllowance)% → \(currentAllowance)% early · next \(nextResetDescription).\n\(usageSummary)"
            )
        }
        return ImmediateUsageNotification(
            identifier: identifier,
            title: "Codex \(windowKind.displayName.lowercased()) usage reset",
            body: "\(account.name)’s \(windowKind.displayName) reset: \(currentAllowance)% left · next \(nextResetDescription).\n\(usageSummary)"
        )
    }

    private static func thresholdNotifications(
        for account: SavedAccount,
        windowKind: UsageWindowKind,
        current: CodexUsageWindow?,
        previous: CodexUsageWindow?,
        thresholds: [Int],
        usageSummary: String,
        now: Date
    ) -> [ImmediateUsageNotification] {
        guard let current, let previous,
              let reset = current.resetsAt,
              let previousReset = previous.resetsAt,
              abs(previousReset.timeIntervalSince(reset)) <= resetTimeCorrectionTolerance
        else { return [] }

        let currentRemaining = max(0, min(100, 100 - current.usedPercent))
        let previousRemaining = max(0, min(100, 100 - previous.usedPercent))
        return thresholds.compactMap { threshold in
            guard previousRemaining >= threshold, currentRemaining < threshold else { return nil }
            return ImmediateUsageNotification(
                identifier: "codex-dashboard-account-usage-threshold-\(account.id.uuidString.lowercased())-\(windowKind.identifier)-\(threshold)-\(Int(previousReset.timeIntervalSinceReferenceDate))",
                title: "Codex \(windowKind.displayName): less than \(threshold)% remaining",
                body: "\(account.name)’s \(windowKind.displayName): \(currentRemaining)% left · resets \(formattedDeadline(reset, style: windowKind.deadlineStyle, relativeTo: now)).\n\(usageSummary)"
            )
        }
    }

    private static func bankedResetExpiryNotifications(
        for account: SavedAccount,
        resets: CodexBankedResetSummary?,
        now: Date
    ) -> [ScheduledUsageNotification] {
        guard let resets, resets.availableCount > 0, let expiration = resets.nextExpiration, expiration > now else {
            return []
        }
        return extendedLeadTimes.map { leadTime in
            let leadTimeDescription = description(for: leadTime)
            return ScheduledUsageNotification(
                identifier: "codex-dashboard-account-deadline-v2-\(account.id.uuidString.lowercased())-banked-reset-expiry-\(identifierComponent(for: leadTime))",
                accountID: account.id,
                accountName: account.name,
                kind: .bankedResetExpiry,
                title: "Banked Codex reset expires in \(leadTimeDescription)",
                body: "\(account.name)’s next banked reset expires \(formattedDeadline(expiration)).",
                deadlineUpdateTitle: "Banked reset expiry changed",
                deadlineDescription: "\(account.name)’s next banked reset will now expire",
                deadlineStyle: .fullDate,
                notificationDate: expiration.addingTimeInterval(-leadTime),
                deadlineDate: expiration
            )
        }
    }

    static func refreshedContent(
        for notification: ScheduledUsageNotification,
        using snapshot: CodexAccountUsageSnapshot,
        now: Date = .now
    ) -> ImmediateUsageNotification? {
        let usage = snapshot.usage
        let body: String
        switch notification.kind {
        case .fiveHourReset:
            guard hasWeeklyUsageRemaining(usage), hasFiveHourUsageRemaining(usage),
                  let fiveHour = usage.fiveHour,
                  let resetsAt = fiveHour.resetsAt,
                  !deadlinesDifferMeaningfully(resetsAt, notification.deadlineDate)
            else { return nil }
            let remaining = max(0, min(100, 100 - fiveHour.usedPercent))
            body = "\(notification.accountName)’s 5-hour: \(remaining)% left · resets "
                + "\(formattedDeadline(resetsAt, style: .todayOrTomorrow, relativeTo: now)).\n"
                + usageSummary(for: usage)
        case .weeklyReset:
            guard hasWeeklyUsageRemaining(usage), let weekly = usage.weekly,
                  let resetsAt = weekly.resetsAt,
                  !deadlinesDifferMeaningfully(resetsAt, notification.deadlineDate)
            else { return nil }
            let remaining = max(0, min(100, 100 - weekly.usedPercent))
            body = "\(notification.accountName)’s Weekly: \(remaining)% left · resets "
                + "\(formattedDeadline(resetsAt, style: .fullDate, relativeTo: now)).\n"
                + usageSummary(for: usage)
        case .bankedResetExpiry:
            guard let resets = usage.bankedResets,
                  resets.availableCount > 0,
                  let expiration = resets.nextExpiration,
                  !deadlinesDifferMeaningfully(expiration, notification.deadlineDate)
            else { return nil }
            let count = resets.availableCount == 1
                ? "1 banked reset"
                : "\(resets.availableCount) banked resets"
            body = "\(notification.accountName): \(count) · next expires "
                + "\(formattedDeadline(expiration)).\n"
                + usageSummary(for: usage)
        }
        return ImmediateUsageNotification(
            identifier: "\(notification.identifier)-fresh-\(Int(snapshot.fetchedAt.timeIntervalSince1970))",
            title: notification.title,
            body: body
        )
    }

    private static func description(for leadTime: TimeInterval) -> String {
        let hours = Int(leadTime / oneHour)
        return hours == 1 ? "one hour" : "\(hours) hours"
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

    private static func hasWeeklyUsageRemaining(_ usage: CodexAccountUsage) -> Bool {
        guard let weekly = usage.weekly else { return true }
        return weekly.usedPercent < 100
    }

    private static func hasFiveHourUsageRemaining(_ usage: CodexAccountUsage) -> Bool {
        guard let fiveHour = usage.fiveHour else { return true }
        return fiveHour.usedPercent < 100
    }

    static func formattedDeadline(
        _ deadline: Date,
        style: UsageDeadlineStyle,
        relativeTo referenceDate: Date
    ) -> String {
        guard style == .todayOrTomorrow else { return formattedDeadline(deadline) }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: deadline)
        return calendar.isDate(deadline, inSameDayAs: referenceDate) ? "at \(time)" : "tomorrow at \(time)"
    }

    static func formattedDeadline(_ deadline: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: deadline)
    }
}
