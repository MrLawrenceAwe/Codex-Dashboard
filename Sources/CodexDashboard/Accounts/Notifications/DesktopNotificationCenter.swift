import Foundation
import UserNotifications

struct DeliveredDesktopNotification {
    let identifier: String
    let title: String
    let deadlineDate: Date?
}

@MainActor
protocol DesktopNotificationCenter: AnyObject {
    func pendingRequests() async -> [UNNotificationRequest]
    func deliveredNotifications() async -> [DeliveredDesktopNotification]
    func removePendingRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func add(_ request: UNNotificationRequest) async throws
    func requestAuthorizationIfNeeded() async -> Bool
}

@MainActor
final class SystemDesktopNotificationCenter: DesktopNotificationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    func deliveredNotifications() async -> [DeliveredDesktopNotification] {
        await center.deliveredNotifications().map { notification in
            let content = notification.request.content
            return DeliveredDesktopNotification(
                identifier: notification.request.identifier,
                title: content.title,
                deadlineDate: (content.userInfo["deadlineTimestamp"] as? TimeInterval)
                    .map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
