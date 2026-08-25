import Foundation
import Security

struct CodexAccountProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastUsedAt: Date
}

struct CodexAccountDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    var profiles: [CodexAccountProfile] = []
    var activeProfileID: UUID?
}

struct DashboardAccountPayload: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isActive: Bool
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
