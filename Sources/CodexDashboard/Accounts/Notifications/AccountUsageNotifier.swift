import Foundation
import UserNotifications

@MainActor
protocol AccountUsageNotifying {
    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async
}

@MainActor
struct NoopAccountUsageNotifier: AccountUsageNotifying {
    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {}
}

@MainActor
final class AccountUsageNotifier: AccountUsageNotifying {
    private static let identifierPrefix = "codex-dashboard-account-deadline-"

    private let notificationCenter: UNUserNotificationCenter
    private let history: UsageNotificationHistory

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        userDefaults: UserDefaults = .standard
    ) {
        self.notificationCenter = notificationCenter
        history = UsageNotificationHistory(userDefaults: userDefaults, channel: .desktop)
    }

    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {
        let currentDate = Date.now
        let plan = UsageNotificationPlanner.plan(
            for: accounts,
            usageByAccountID: usageByAccountID,
            previousObservations: history.observations(),
            previousDeadlines: history.deadlines(for: .known),
            sentUpdates: history.deadlines(for: .updates),
            now: currentDate
        )
        history.saveDeadlines(plan.unchangedDeadlines, for: .known)
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        let existingIdentifiers = pendingRequests.compactMap { request in
            request.identifier.hasPrefix(Self.identifierPrefix) ? request.identifier : nil
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: existingIdentifiers)

        let requests = plan.scheduled
        let immediateNotifications = plan.immediate
        guard !requests.isEmpty || !immediateNotifications.isEmpty, await notificationsAreAuthorized() else {
            history.saveObservations(for: accounts, usageByAccountID: usageByAccountID)
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
                    history.saveDeadlines([notification], for: .known)
                    history.saveDeadlines([notification], for: .updates)
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
        history.saveObservations(for: accounts, usageByAccountID: usageByAccountID)
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
