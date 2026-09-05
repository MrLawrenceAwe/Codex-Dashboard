import Foundation
import UserNotifications

@MainActor
protocol CompatibilityIssueNotifying {
    func notify(report: CompatibilityReport) async
}

@MainActor
struct NoopCompatibilityIssueNotifier: CompatibilityIssueNotifying {
    func notify(report: CompatibilityReport) async {}
}

@MainActor
final class CompatibilityIssueNotifier: CompatibilityIssueNotifying {
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func notify(report: CompatibilityReport) async {
        let granted: Bool
        do {
            granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
        } catch {
            return
        }
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = report.blockingCount > 0
            ? "Codex Dashboard is incompatible"
            : "Codex Dashboard needs attention"
        let reason = report.attentionSummary ?? report.summary
        content.body = "A Codex update triggered compatibility checks: \(reason) Review Diagnostics from the menu bar."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex-dashboard-update-compatibility",
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }
}
