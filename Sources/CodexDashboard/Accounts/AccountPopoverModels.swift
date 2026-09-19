import Foundation

struct AccountPopoverSnapshot: Codable, Equatable, Sendable {
    let accounts: [AccountPopoverItem]
    let activeAccountID: UUID?
    let statusMessage: String?
    let isBusy: Bool
}

struct AccountPopoverItem: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isActive: Bool
    let usageLines: [String]
    let isRefreshing: Bool
    let requiresSignIn: Bool
    let errorMessage: String?
}

struct AccountPopoverAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case updateUsage
        case refreshInactiveUsage
        case saveCurrentAccount
        case switchAccount
        case addAccount
        case forgetAccount
    }

    let kind: Kind
    let accountID: UUID?
}

enum AccountPopoverActionWaitResult: Equatable, Sendable {
    case action(AccountPopoverAction)
    case timedOut
    case unavailable
}

enum AccountPopoverActionHandlingOutcome: Equatable, Sendable {
    case handled
    case timedOut
    case unavailable
}
