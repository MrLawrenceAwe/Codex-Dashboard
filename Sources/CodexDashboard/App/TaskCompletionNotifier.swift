import Foundation
import UserNotifications

@MainActor
protocol TaskCompletionNotifying {
    func prepare() async -> String?
    func notify(completions: [TaskCompletion]) async -> String?
}

@MainActor
struct NoopTaskCompletionNotifier: TaskCompletionNotifying {
    func prepare() async -> String? { nil }
    func notify(completions: [TaskCompletion]) async -> String? { nil }
}

@MainActor
final class TaskCompletionNotifier: NSObject, TaskCompletionNotifying, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    var openInbox: (() -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func prepare() async -> String? {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return granted ? nil : "Notifications are off in macOS. Enable them for Codex Dashboard in System Settings → Notifications. Completions still appear here."
        } catch {
            return "Notifications could not be enabled: \(error.localizedDescription) Completions still appear here."
        }
    }

    func notify(completions: [TaskCompletion]) async -> String? {
        guard let newest = completions.first else { return nil }
        if let notice = await prepare() { return notice }
        let content = UNMutableNotificationContent()
        content.title = completions.count == 1 ? "Codex task completed" : "\(completions.count) Codex tasks completed"
        content.body = completions.count == 1
            ? "\(newest.title)\n\(newest.projectName)"
            : completions.prefix(3).map(\.title).joined(separator: "\n")
        content.sound = .default
        content.userInfo = ["completionInbox": true]
        do {
            try await center.add(UNNotificationRequest(
                identifier: "codex-completion-\(UUID().uuidString)", content: content, trigger: nil
            ))
            return nil
        } catch {
            return "A completion notification could not be delivered: \(error.localizedDescription) Completions still appear here."
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.userInfo["completionInbox"] as? Bool == true,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.openInbox?() }
    }
}
