import Foundation

struct DashboardDiagnostics {
    let dashboardVersion: String
    let codexVersion: String
    let status: String
    let rendererTargetCount: Int
    let loadedThreadCount: Int
    let totalThreadCount: Int
    let lastRefresh: Date?
    let lastCompatibilityCheck: Date?
    let compatibilitySummary: String
    let connectionError: String?
    let threadWarning: String?
    let promptBackupPath: String

    var text: String {
        let formatter = ISO8601DateFormatter()
        return [
            "Codex Dashboard \(dashboardVersion)",
            "Codex: \(codexVersion)",
            "Status: \(status)",
            "Renderer targets: \(rendererTargetCount)",
            "Threads: \(loadedThreadCount) loaded / \(totalThreadCount) total",
            "Last refresh: \(lastRefresh.map(formatter.string(from:)) ?? "never")",
            "Last compatibility check: \(lastCompatibilityCheck.map(formatter.string(from:)) ?? "never")",
            "Compatibility: \(compatibilitySummary)",
            "Connection error: \(connectionError ?? "none")",
            "Thread warning: \(threadWarning ?? "none")",
            "Prompt backup: \(promptBackupPath)",
        ].joined(separator: "\n")
    }
}
