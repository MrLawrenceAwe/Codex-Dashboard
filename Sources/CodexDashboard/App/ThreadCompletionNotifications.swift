import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let codexDashboardOpenCompletedThread = Notification.Name(
        "CodexDashboardOpenCompletedThread"
    )
}

enum CompletionNotificationPayload {
    static let threadIDKey = "thread-id"

    static func threadID(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo[threadIDKey] as? String
    }
}

@MainActor
protocol ThreadCompletionNotifying: AnyObject {
    func requestAuthorization()
    func postCompletion(for thread: ThreadSummary)
}

@MainActor
final class DisabledThreadCompletionNotifier: ThreadCompletionNotifying {
    func requestAuthorization() {}
    func postCompletion(for thread: ThreadSummary) {}
}

struct ThreadCompletionDetector {
    private var previousThreadsByID: [String: ThreadSummary]?
    private var deliveredUnreadThreadIDs: Set<String> = []

    mutating func observe(_ threads: [ThreadSummary]) -> [ThreadSummary] {
        let currentThreadsByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        guard let previousThreadsByID else {
            self.previousThreadsByID = currentThreadsByID
            return []
        }

        var completedThreads: [ThreadSummary] = []
        for thread in threads {
            guard let previous = previousThreadsByID[thread.id] else { continue }

            if thread.runState == .running || (previous.isUnread && !thread.isUnread) {
                deliveredUnreadThreadIDs.remove(thread.id)
            }

            if
                previous.runState == .running,
                thread.runState == .idle,
                thread.lastRunTermination != .aborted
            {
                completedThreads.append(thread)
                deliveredUnreadThreadIDs.insert(thread.id)
            } else if
                !previous.isUnread,
                thread.isUnread,
                thread.runState == .idle,
                !deliveredUnreadThreadIDs.contains(thread.id)
            {
                // Unread state is refreshed more frequently than the full activity snapshot.
                // This catches short turns that start and finish between activity polls.
                completedThreads.append(thread)
                deliveredUnreadThreadIDs.insert(thread.id)
            }
        }

        deliveredUnreadThreadIDs.formIntersection(currentThreadsByID.keys)
        self.previousThreadsByID = currentThreadsByID
        return completedThreads
    }
}

@MainActor
final class MacThreadCompletionNotifier: NSObject, ThreadCompletionNotifying,
    UNUserNotificationCenterDelegate
{
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("Codex Dashboard notification authorization failed: %@", error.localizedDescription)
            }
        }
    }

    func postCompletion(for thread: ThreadSummary) {
        let content = UNMutableNotificationContent()
        content.title = "Codex finished"
        content.subtitle = thread.title
        content.body = Self.notificationBody(for: thread)
        content.sound = .default
        content.userInfo = [CompletionNotificationPayload.threadIDKey: thread.id]

        let request = UNNotificationRequest(
            identifier: "codex-complete-\(thread.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Codex Dashboard notification delivery failed: %@", error.localizedDescription)
            }
        }
    }

    static func notificationBody(for thread: ThreadSummary) -> String {
        let message = thread.lastAssistantMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard let message, !message.isEmpty else {
            return "Response ready in \(thread.projectName)"
        }
        let maximumLength = 320
        guard message.count > maximumLength else { return message }
        let endIndex = message.index(message.startIndex, offsetBy: maximumLength - 1)
        return String(message[..<endIndex]) + "…"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let completedThreadID = CompletionNotificationPayload.threadID(
            from: response.notification.request.content.userInfo
        )
        await MainActor.run {
            let bundleIdentifier = "com.openai.codex"
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first {
                running.activate(options: [.activateAllWindows])
            } else if let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) {
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
            guard let completedThreadID else { return }
            NotificationCenter.default.post(
                name: .codexDashboardOpenCompletedThread,
                object: nil,
                userInfo: [CompletionNotificationPayload.threadIDKey: completedThreadID]
            )
        }
    }
}
