import Foundation

enum AccountDocumentMigration {
    struct Result {
        let document: SavedAccountsDocument
        let requiresNameFallback: Bool
        let requiresIdentitySynchronization: Bool
        let requiresRewrite: Bool
    }

    static func decode(
        _ data: Data,
        version: Int,
        accountIdentifier: @escaping (UUID) -> String?
    ) throws -> Result {
        switch version {
        case SavedAccountsDocument.currentVersion:
            return Result(
                document: try JSONDecoder().decode(SavedAccountsDocument.self, from: data),
                requiresNameFallback: false,
                requiresIdentitySynchronization: false,
                requiresRewrite: false
            )
        case 4:
            return Result(
                document: try currentDocument(from: data),
                requiresNameFallback: false,
                requiresIdentitySynchronization: false,
                requiresRewrite: true
            )
        case 3:
            return Result(
                document: try currentDocument(from: data),
                requiresNameFallback: false,
                requiresIdentitySynchronization: true,
                requiresRewrite: true
            )
        case 1, 2:
            return Result(
                document: try currentDocument(from: data, accountIdentifier: accountIdentifier),
                requiresNameFallback: true,
                requiresIdentitySynchronization: true,
                requiresRewrite: true
            )
        default:
            throw CodexAccountError.unsupportedMetadataVersion(version)
        }
    }

    private static func currentDocument(
        from data: Data,
        accountIdentifier: ((UUID) -> String?)? = nil
    ) throws -> SavedAccountsDocument {
        let legacy = try JSONDecoder().decode(LegacySavedAccountsDocument.self, from: data)
        return SavedAccountsDocument(
            accounts: legacy.accounts.map { account in
                SavedAccount(
                    id: account.id,
                    name: account.name,
                    createdAt: account.createdAt,
                    lastUsedAt: account.lastUsedAt,
                    accountIdentifier: account.accountIdentifier
                        ?? accountIdentifier?(account.id)
                )
            },
            activeAccountID: legacy.activeAccountID
        )
    }
}

private struct LegacySavedAccount: Decodable {
    let id: UUID
    let name: String
    let createdAt: Date
    let lastUsedAt: Date
    let accountIdentifier: String?
}

private struct LegacySavedAccountsDocument: Decodable {
    let accounts: [LegacySavedAccount]
    let activeAccountID: UUID?

    private enum CodingKeys: String, CodingKey {
        case accounts = "profiles"
        case activeAccountID = "activeProfileID"
    }
}
