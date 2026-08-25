import Foundation

enum AccountDocumentMigration {
    struct Result {
        let document: SavedAccountsDocument
        let requiresNameFallback: Bool
    }

    static func decode(
        _ data: Data,
        version: Int,
        accountIdentifier: (UUID) -> String?
    ) throws -> Result {
        switch version {
        case SavedAccountsDocument.currentVersion:
            return Result(
                document: try JSONDecoder().decode(SavedAccountsDocument.self, from: data),
                requiresNameFallback: false
            )
        case 2:
            var document = try JSONDecoder().decode(SavedAccountsDocument.self, from: data)
            document.version = SavedAccountsDocument.currentVersion
            return Result(document: document, requiresNameFallback: true)
        case 1:
            let legacy = try JSONDecoder().decode(LegacySavedAccountsDocument.self, from: data)
            return Result(
                document: SavedAccountsDocument(
                    accounts: legacy.accounts.map { account in
                        SavedAccount(
                            id: account.id,
                            name: account.name,
                            createdAt: account.createdAt,
                            lastUsedAt: account.lastUsedAt,
                            accountIdentifier: accountIdentifier(account.id)
                        )
                    },
                    activeAccountID: legacy.activeAccountID
                ),
                requiresNameFallback: true
            )
        default:
            throw CodexAccountError.unsupportedMetadataVersion(version)
        }
    }
}

private struct LegacySavedAccount: Decodable {
    let id: UUID
    let name: String
    let createdAt: Date
    let lastUsedAt: Date
}

private struct LegacySavedAccountsDocument: Decodable {
    let accounts: [LegacySavedAccount]
    let activeAccountID: UUID?

    private enum CodingKeys: String, CodingKey {
        case accounts = "profiles"
        case activeAccountID = "activeProfileID"
    }
}
