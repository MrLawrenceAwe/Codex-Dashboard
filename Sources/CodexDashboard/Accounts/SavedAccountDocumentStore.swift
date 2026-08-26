import Foundation

final class SavedAccountDocumentStore: @unchecked Sendable {
    private let metadataURL: URL
    private let vault: any AccountCredentialVault
    private let activeCredentialFile: ActiveCodexCredentialFile
    private let fileManager: FileManager

    init(
        metadataURL: URL,
        vault: any AccountCredentialVault,
        activeCredentialFile: ActiveCodexCredentialFile,
        fileManager: FileManager
    ) {
        self.metadataURL = metadataURL
        self.vault = vault
        self.activeCredentialFile = activeCredentialFile
        self.fileManager = fileManager
    }

    func load() throws -> SavedAccountsDocument {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return SavedAccountsDocument()
        }
        let data = try Data(contentsOf: metadataURL)
        let storedVersion = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }?["version"] as? Int
        let migration = try AccountDocumentMigration.decode(
            data,
            version: storedVersion ?? 0,
            accountIdentifier: { [vault] accountID in
                (try? vault.credentialWithoutUserInteraction(for: accountID))
                    .flatMap { AccountIdentityDecoder.identity(in: $0)?.identifier }
            }
        )
        var document = migration.document
        let original = document
        if migration.requiresIdentitySynchronization {
            synchronizeSavedAccountIdentities(in: &document)
        }
        reconcileActiveAccount(in: &document, allowNameFallback: migration.requiresNameFallback)
        if document != original
            || migration.requiresNameFallback
            || migration.requiresIdentitySynchronization
        {
            try save(document)
        }
        return document
    }

    private func synchronizeSavedAccountIdentities(in document: inout SavedAccountsDocument) {
        for index in document.accounts.indices {
            guard
                let credential = try? vault.credentialWithoutUserInteraction(
                    for: document.accounts[index].id
                ),
                let identity = AccountIdentityDecoder.identity(in: credential)
            else { continue }
            document.accounts[index].name = identity.accountName
            document.accounts[index].accountIdentifier = identity.identifier
        }
    }

    func save(_ document: SavedAccountsDocument) throws {
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: metadataURL, options: [.atomic])
    }

    private func reconcileActiveAccount(
        in document: inout SavedAccountsDocument,
        allowNameFallback: Bool
    ) {
        guard let credential = try? activeCredentialFile.read() else {
            document.activeAccountID = nil
            return
        }
        guard let identity = AccountIdentityDecoder.identity(in: credential) else { return }
        if let account = document.accounts.first(where: {
            $0.accountIdentifier == identity.identifier
        }) {
            document.activeAccountID = account.id
            return
        }
        if allowNameFallback, let displayName = identity.displayName {
            let candidates = document.accounts.indices.filter {
                document.accounts[$0].accountIdentifier == nil
                    && AccountIdentityDecoder.accountName(
                        document.accounts[$0].name,
                        matches: displayName
                    )
            }
            if candidates.count == 1, let index = candidates.first {
                document.accounts[index].accountIdentifier = identity.identifier
                document.activeAccountID = document.accounts[index].id
                return
            }
        }
        document.activeAccountID = nil
    }
}
