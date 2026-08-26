import Foundation
import Security

struct SavedAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastUsedAt: Date
    var accountIdentifier: String?
}

struct SavedAccountsDocument: Codable, Equatable, Sendable {
    static let currentVersion = 4

    var version = Self.currentVersion
    var accounts: [SavedAccount] = []
    var activeAccountID: UUID?

    private enum CodingKeys: String, CodingKey {
        case version
        case accounts = "profiles"
        case activeAccountID = "activeProfileID"
    }
}

struct SavedAccountOption: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isActive: Bool
}

struct CodexUsageWindow: Codable, Equatable, Sendable {
    let usedPercent: Int
    let resetsAt: Date?
}

struct CodexAccountUsage: Codable, Equatable, Sendable {
    let fiveHour: CodexUsageWindow?
    let weekly: CodexUsageWindow?
    let bankedResets: CodexBankedResetSummary?

    init(
        fiveHour: CodexUsageWindow?,
        weekly: CodexUsageWindow?,
        bankedResets: CodexBankedResetSummary? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.bankedResets = bankedResets
    }
}

struct CodexBankedResetSummary: Codable, Equatable, Sendable {
    let availableCount: Int
    let nextExpiration: Date?
}

struct CodexAccountUsageSnapshot: Codable, Equatable, Sendable {
    let usage: CodexAccountUsage
    let fetchedAt: Date
}

enum CodexAccountUsageStatus: Equatable, Sendable {
    case loading(previous: CodexAccountUsageSnapshot?)
    case available(CodexAccountUsageSnapshot)
    case stale(CodexAccountUsageSnapshot)
    case unavailable

    var snapshot: CodexAccountUsageSnapshot? {
        switch self {
        case .loading(let previous): previous
        case .available(let snapshot), .stale(let snapshot): snapshot
        case .unavailable: nil
        }
    }
}

struct DashboardAccountAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case save
        case add
        case switchAccount = "switch"
    }

    let type: Kind
    let accountID: UUID?
}

enum CodexAccountError: LocalizedError {
    case noActiveCredential
    case missingCredential(String)
    case accountNotFound
    case activeTasks
    case accountIdentityUnavailable
    case invalidCredential
    case keychain(OSStatus)
    case recoveryFailed(String)
    case unsupportedMetadataVersion(Int)

    var errorDescription: String? {
        switch self {
        case .noActiveCredential:
            return "Codex is not signed in. Sign in first, then save the account."
        case .missingCredential(let name):
            return "The saved credentials for \(name) are unavailable. Save that account again."
        case .accountNotFound:
            return "The selected Codex account no longer exists."
        case .activeTasks:
            return "Wait for active Codex tasks to finish before switching accounts."
        case .accountIdentityUnavailable:
            return "Codex could not read the signed-in account identity. Sign in again, then save the account."
        case .invalidCredential:
            return "Codex authentication data is invalid and was not saved or activated."
        case .keychain(let status):
            return "The Codex account credential could not be accessed in Keychain (\(status))."
        case .recoveryFailed(let detail):
            return "The Codex account change could not be recovered safely. \(detail)"
        case .unsupportedMetadataVersion(let version):
            return "The saved account list uses unsupported version \(version). Update Codex Dashboard before changing accounts."
        }
    }
}
