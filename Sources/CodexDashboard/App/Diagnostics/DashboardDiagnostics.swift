import Foundation

struct DashboardDiagnostics {
    static func versionDescription(in bundle: Bundle = .main) -> String {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(shortVersion) (\($0))" } ?? shortVersion
    }

    let dashboardVersion: String
    let codexVersion: String
    let status: String
    let rendererTargetCount: Int
    let loadedThreadCount: Int
    let totalThreadCount: Int
    let lastRefresh: Date?
    let lastCompatibilityCheck: Date?
    let compatibilitySummary: String
    let compatibilityDetails: [String]
    let connectionError: String?
    let connectionNotice: String?
    let threadWarning: String?

    var text: String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Codex Dashboard \(dashboardVersion)",
            "Codex: \(codexVersion)",
            "Status: \(status)",
            "Renderer targets: \(rendererTargetCount)",
            "Chats: \(loadedThreadCount) loaded / \(totalThreadCount) total",
            "Last refresh: \(lastRefresh.map(formatter.string(from:)) ?? "never")",
            "Last compatibility check: \(lastCompatibilityCheck.map(formatter.string(from:)) ?? "never")",
            "Compatibility: \(compatibilitySummary)",
            "Connection error: \(connectionError ?? "none")",
            "Connection notice: \(connectionNotice ?? "none")",
            "Chat warning: \(threadWarning ?? "none")",
        ]
        lines.append(contentsOf: compatibilityDetails.map { "Compatibility detail: \($0)" })
        return lines.joined(separator: "\n")
    }
}
