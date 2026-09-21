import Foundation
import UserNotifications

typealias DeadlineUsageRefreshHandler = @MainActor @Sendable (UUID) async -> CodexAccountUsageSnapshot?

@MainActor
protocol AccountUsageNotifying {
    func setDeadlineUsageRefreshHandler(_ handler: @escaping DeadlineUsageRefreshHandler)
    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async
}

@MainActor
struct NoopAccountUsageNotifier: AccountUsageNotifying {
    func setDeadlineUsageRefreshHandler(_ handler: @escaping DeadlineUsageRefreshHandler) {}

    func updateNotifications(
        for accounts: [SavedAccount],
        usageByAccountID: [UUID: CodexAccountUsageSnapshot]
    ) async {}
}

@MainActor
final class AccountUsageNotifier: AccountUsageNotifying {
    private static let identifierPrefix = "codex-dashboard-account-deadline-"
    private static let fallbackDelay: TimeInterval = 30

    private let notificationCenter: UNUserNotificationCenter
    private let history: UsageNotificationHistory
    private var deadlineUsageRefresh: DeadlineUsageRefreshHandler?
    private var liveTasksByIdentifier: [String: Task<Void, Never>] = [:]
    private var liveNotificationsByIdentifier: [String: ScheduledUsageNotification] = [:]

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        userDefaults: UserDefaults = .standard
    ) {
        self.notificationCenter = notificationCenter
        history = UsageNotificationHistory(userDefaults: userDefaults, channel: .desktop)
    }

    deinit {
        liveTasksByIdentifier.values.forEach { $0.cancel() }
    }

    func setDeadlineUsageRefreshHandler(_ handler: @escaping DeadlineUsageRefreshHandler) {
        deadlineUsageRefresh = handler
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
        var requestsByIdentifier = Dictionary(
            uniqueKeysWithValues: plan.scheduled.map { ($0.identifier, $0) }
        )
        for notification in plan.unchangedDeadlines where
            !notification.isDeadlineUpdate
                && notification.notificationDate.addingTimeInterval(Self.fallbackDelay) > currentDate
        {
            requestsByIdentifier[notification.identifier] = notification
        }
        let requests = requestsByIdentifier.values.sorted { $0.identifier < $1.identifier }
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        let existingIdentifiers = pendingRequests.compactMap { request in
            request.identifier.hasPrefix(Self.identifierPrefix) ? request.identifier : nil
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: existingIdentifiers)

        let immediateNotifications = plan.immediate
        guard !requests.isEmpty || !immediateNotifications.isEmpty, await notificationsAreAuthorized() else {
            cancelAllLiveTasks()
            history.saveObservations(for: accounts, usageByAccountID: usageByAccountID)
            return
        }
        reconcileLiveDeliveries(requests.filter { !$0.isDeadlineUpdate }, now: currentDate)
        for notification in requests {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
                    from: notification.notificationDate.addingTimeInterval(
                        notification.isDeadlineUpdate ? 0 : Self.fallbackDelay
                    )
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

    private func reconcileLiveDeliveries(
        _ notifications: [ScheduledUsageNotification],
        now: Date
    ) {
        let desired = Dictionary(uniqueKeysWithValues: notifications.map { ($0.identifier, $0) })
        for identifier in Set(liveTasksByIdentifier.keys).subtracting(desired.keys) {
            cancelLiveTask(identifier)
        }
        for notification in notifications {
            if liveNotificationsByIdentifier[notification.identifier] == notification { continue }
            cancelLiveTask(notification.identifier)
            liveNotificationsByIdentifier[notification.identifier] = notification
            let delay = max(0, notification.notificationDate.timeIntervalSince(now))
            liveTasksByIdentifier[notification.identifier] = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                await self?.deliverFresh(notification)
            }
        }
    }

    private func deliverFresh(_ notification: ScheduledUsageNotification) async {
        guard liveNotificationsByIdentifier[notification.identifier] == notification,
              let deadlineUsageRefresh,
              let snapshot = await deadlineUsageRefresh(notification.accountID),
              !Task.isCancelled,
              liveNotificationsByIdentifier[notification.identifier] == notification
        else { return }
        guard let refreshed = UsageNotificationPlanner.refreshedContent(
            for: notification, using: snapshot, now: .now
        ) else {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: [notification.identifier])
            cancelLiveTask(notification.identifier)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = refreshed.title
        content.body = refreshed.body
        content.sound = .default
        do {
            try await notificationCenter.add(
                UNNotificationRequest(identifier: refreshed.identifier, content: content, trigger: nil)
            )
        } catch {
            return
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [notification.identifier])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [notification.identifier])
        cancelLiveTask(notification.identifier)
    }

    private func cancelLiveTask(_ identifier: String) {
        liveTasksByIdentifier[identifier]?.cancel()
        liveTasksByIdentifier[identifier] = nil
        liveNotificationsByIdentifier[identifier] = nil
    }

    private func cancelAllLiveTasks() {
        liveTasksByIdentifier.values.forEach { $0.cancel() }
        liveTasksByIdentifier = [:]
        liveNotificationsByIdentifier = [:]
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
