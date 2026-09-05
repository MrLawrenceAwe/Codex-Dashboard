import Foundation

enum CompatibilityStatus: Sendable {
    case compatible
    case warning
    case incompatible
    case unavailable
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

    var warningCount: Int {
        checks.count { $0.status == .warning || $0.status == .unavailable }
    }

    var summary: String {
        if blockingCount > 0 {
            return "\(blockingCount) incompatible \u{00b7} \(warningCount) need attention"
        }
        if warningCount > 0 {
            return "Core contracts compatible \u{00b7} \(warningCount) need attention"
        }
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
            "\(Self.label(for: check.status)) — \(check.title): \(check.detail)"
        }
    }

    private static func label(for status: CompatibilityStatus) -> String {
        switch status {
        case .compatible: "Compatible"
        case .warning: "Warning"
        case .incompatible: "Incompatible"
        case .unavailable: "Not checked"
        }
    }
}
