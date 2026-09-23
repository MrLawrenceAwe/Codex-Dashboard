import Foundation

struct RateLimitsResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let rateLimits: RateLimitSnapshot
        let rateLimitResetCredits: RateLimitResetCredits?

        var accountUsage: CodexAccountUsage {
            rateLimits.accountUsage(bankedResets: rateLimitResetCredits?.summary)
        }
    }
}

struct RateLimitSnapshot: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?

    func accountUsage(bankedResets: CodexBankedResetSummary?) -> CodexAccountUsage {
        let windows = [primary, secondary].compactMap { $0 }
        return CodexAccountUsage(
            fiveHour: windows.first { $0.windowDurationMins == 300 }?.usageWindow
                ?? (primary?.windowDurationMins == nil ? primary?.usageWindow : nil),
            weekly: windows.first { $0.windowDurationMins == 10_080 }?.usageWindow
                ?? (secondary?.windowDurationMins == nil ? secondary?.usageWindow : nil),
            bankedResets: bankedResets
        )
    }
}

struct RateLimitResetCredits: Decodable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]?

    var summary: CodexBankedResetSummary {
        CodexBankedResetSummary(
            availableCount: max(0, availableCount),
            nextExpiration: credits?
                .filter { $0.status == "available" }
                .compactMap(\.expiresAt)
                .min()
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

struct RateLimitResetCredit: Decodable {
    let status: String
    let expiresAt: Int64?
}

struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var usageWindow: CodexUsageWindow {
        CodexUsageWindow(
            usedPercent: min(100, max(0, usedPercent)),
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
