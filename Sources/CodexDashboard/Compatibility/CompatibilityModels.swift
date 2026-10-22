import Foundation

enum CompatibilityStatus: Sendable {
    case compatible
    case warning
    case incompatible
    case unavailable

    var label: String {
        switch self {
        case .compatible: "Compatible"
        case .warning: "Warning"
        case .incompatible: "Incompatible"
        case .unavailable: "Unavailable"
        }
    }
}

struct CompatibilityCheck: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: CompatibilityStatus
    let detail: String
}

struct CompatibilityReport: Equatable, Sendable {
    let checks: [CompatibilityCheck]

    var attentionChecks: [CompatibilityCheck] {
        checks.filter { $0.status != .compatible }
    }

    var blockingCount: Int {
        checks.count { $0.status == .incompatible }
    }

    var nonBlockingAttentionCount: Int {
        checks.count { $0.status == .warning || $0.status == .unavailable }
    }

    var summary: String {
        if blockingCount > 0 {
            return "\(blockingCount) incompatible \u{00b7} \(nonBlockingAttentionCount) need attention"
        }
        let unavailableCount = checks.count { $0.status == .unavailable }
        if unavailableCount > 0 {
            return "Compatibility checks incomplete \u{00b7} \(unavailableCount) unavailable \u{00b7} \(nonBlockingAttentionCount) need attention"
        }
        if nonBlockingAttentionCount > 0 {
            return "Compatibility checks need attention \u{00b7} \(nonBlockingAttentionCount) \(nonBlockingAttentionCount == 1 ? "warning" : "warnings")"
        }
        if checks.isEmpty { return "Compatibility not checked" }
        return "All checked contracts are compatible"
    }

    var attentionSummary: String? {
        guard let first = attentionChecks.first else { return nil }
        let remainingCount = attentionChecks.count - 1
        let suffix = remainingCount > 0 ? " (+\(remainingCount) more)" : ""
        return "\(first.title): \(first.detail)\(suffix)"
    }

    var diagnosticLines: [String] {
        attentionChecks.map { check in
            "\(check.status.label) — \(check.title): \(check.detail)"
        }
    }
}
