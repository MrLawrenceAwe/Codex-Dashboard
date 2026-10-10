import Foundation

struct AccountPopoverSnapshot: Codable, Equatable, Sendable {
    let accounts: [AccountPopoverItem]
    let activeAccountID: UUID?
    let statusMessage: String?
    let isBusy: Bool
    let usageBlockage: AccountUsageBlockage?
}

struct AccountUsageBlockage: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let label: String
        let resetsAtMilliseconds: Double?
    }

    let windows: [Window]
    let isStale: Bool
}

/// A labelled usage value, or a status note when label is nil.
struct AccountUsageRow: Codable, Equatable, Sendable {
    let label: String?
    let value: String
}

struct AccountPopoverItem: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isActive: Bool
    let usageRows: [AccountUsageRow]
    let isRefreshing: Bool
    let requiresSignIn: Bool
    let errorMessage: String?
}

struct AccountPopoverAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case refreshUsage
        case refreshInactiveUsage
        case saveCurrentAccount
        case switchAccount
        case restartForSignIn
        case removeSavedAccount
    }

    let kind: Kind
    let accountID: UUID?
}

enum AccountPopoverActionPollResult: Equatable, Sendable {
    case action(AccountPopoverAction)
    case empty
    case unavailable
}

enum AccountPopoverActionHandlingOutcome: Equatable, Sendable {
    case handled
    case empty
    case unavailable
}
