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
}
