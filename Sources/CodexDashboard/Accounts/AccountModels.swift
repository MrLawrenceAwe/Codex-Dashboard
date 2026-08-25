import Foundation
import Security

struct CodexAccountProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastUsedAt: Date
    var accountIdentifier: String?
}

struct CodexAccountDocument: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version = Self.currentVersion
    var profiles: [CodexAccountProfile] = []
    var activeProfileID: UUID?
}

struct DashboardAccountPayload: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isActive: Bool
    let usage: DashboardAccountUsagePayload?

    init(
        id: String,
        name: String,
        isActive: Bool,
        usage: DashboardAccountUsagePayload? = nil
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.usage = usage
    }
}

struct CodexUsageWindow: Equatable, Sendable {
    let usedPercent: Int
    let resetsAt: Date?
}

struct CodexAccountUsage: Equatable, Sendable {
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

struct CodexBankedResetSummary: Equatable, Sendable {
    let availableCount: Int
    let nextExpiration: Date?
}

struct CodexAccountUsageSnapshot: Equatable, Sendable {
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

struct DashboardUsageWindowPayload: Codable, Equatable, Sendable {
    let usedPercent: Int
    let resetsAtMilliseconds: Int64?

    init(_ window: CodexUsageWindow) {
        usedPercent = window.usedPercent
        resetsAtMilliseconds = window.resetsAt.map {
            Int64(($0.timeIntervalSince1970 * 1_000).rounded())
        }
    }
}

struct DashboardAccountUsagePayload: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case loading
        case available
        case stale
        case unavailable
    }

    let state: State
    let fiveHour: DashboardUsageWindowPayload?
    let weekly: DashboardUsageWindowPayload?
    let bankedResets: DashboardBankedResetPayload?
    let fetchedAtMilliseconds: Int64?

    init(_ status: CodexAccountUsageStatus) {
        switch status {
        case .loading: state = .loading
        case .available: state = .available
        case .stale: state = .stale
        case .unavailable: state = .unavailable
        }
        let snapshot = status.snapshot
        fiveHour = snapshot?.usage.fiveHour.map(DashboardUsageWindowPayload.init)
        weekly = snapshot?.usage.weekly.map(DashboardUsageWindowPayload.init)
        bankedResets = snapshot?.usage.bankedResets.map(DashboardBankedResetPayload.init)
        fetchedAtMilliseconds = snapshot.map {
            Int64(($0.fetchedAt.timeIntervalSince1970 * 1_000).rounded())
        }
    }
}

struct DashboardBankedResetPayload: Codable, Equatable, Sendable {
    let availableCount: Int
    let nextExpirationMilliseconds: Int64?

    init(_ summary: CodexBankedResetSummary) {
        availableCount = summary.availableCount
        nextExpirationMilliseconds = summary.nextExpiration.map {
            Int64(($0.timeIntervalSince1970 * 1_000).rounded())
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
    let profileID: UUID?
    let name: String?
}

enum CodexAccountError: LocalizedError {
    case noActiveCredential
    case missingCredential(String)
    case invalidProfile
    case activeTasks
    case accountNameRequired
    case invalidCredential
    case keychain(OSStatus)
    case unsupportedMetadataVersion(Int)

    var errorDescription: String? {
        switch self {
        case .noActiveCredential:
            return "Codex is not signed in. Sign in first, then save the account."
        case .missingCredential(let name):
            return "The saved credentials for \(name) are unavailable. Save that account again."
        case .invalidProfile:
            return "The selected Codex account no longer exists."
        case .activeTasks:
            return "Wait for active Codex tasks to finish before switching accounts."
        case .accountNameRequired:
            return "Enter a name for this Codex account."
        case .invalidCredential:
            return "Codex authentication data is invalid and was not saved or activated."
        case .keychain(let status):
            return "The Codex account credential could not be accessed in Keychain (\(status))."
        case .unsupportedMetadataVersion(let version):
            return "The saved account list uses unsupported version \(version). Update Codex Dashboard before changing accounts."
        }
    }
}
