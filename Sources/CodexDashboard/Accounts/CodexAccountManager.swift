import Foundation

struct AccountTransition: Sendable {
    fileprivate let previousCredential: Data?
    fileprivate let previousDocument: SavedAccountsDocument
}

final class CodexAccountManager: @unchecked Sendable {
    private let vault: any AccountCredentialVault
    private let activeCredentialFile: ActiveCodexCredentialFile
    private let documentStore: SavedAccountDocumentStore
    private let now: () -> Date
    private let lock = NSLock()
    let usageCacheStore: any UsageCaching

    init(
        metadataURL: URL = CodexConfiguration.accountMetadataURL,
        authenticationURL: URL = CodexConfiguration.authenticationURL,
        vault: any AccountCredentialVault = KeychainAccountCredentialVault(),
        fileManager: FileManager = .default,
        usageCacheStore: (any UsageCaching)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.vault = vault
        let activeCredentialFile = ActiveCodexCredentialFile(
            url: authenticationURL,
            fileManager: fileManager
        )
        self.activeCredentialFile = activeCredentialFile
        documentStore = SavedAccountDocumentStore(
            metadataURL: metadataURL,
            vault: vault,
            activeCredentialFile: activeCredentialFile,
            fileManager: fileManager
        )
        self.usageCacheStore = usageCacheStore ?? UsageCache(
            cacheURL: metadataURL.deletingLastPathComponent()
                .appendingPathComponent("account-usage.json"),
            fileManager: fileManager
        )
        self.now = now
    }

    func activeAccountIdentifier() throws -> String? {
        try lock.withLock {
            try activeCredentialFile.read().flatMap { AccountIdentityDecoder.identity(in: $0)?.identifier }
        }
    }

    func document() throws -> SavedAccountsDocument {
        try lock.withLock { try documentStore.load() }
    }

    func savedCredentialWithoutUserInteraction(for accountID: UUID) throws -> Data {
        try savedCredential(for: accountID, interactionAllowed: false)
    }

    func savedCredentialAllowingUserInteraction(for accountID: UUID) throws -> Data {
        try savedCredential(for: accountID, interactionAllowed: true)
    }

    private func savedCredential(
        for accountID: UUID,
        interactionAllowed: Bool
    ) throws -> Data {
        try lock.withLock {
            let document = try documentStore.load()
            guard let account = document.accounts.first(where: { $0.id == accountID }) else {
                throw CodexAccountError.accountNotFound
            }
            let credential = try interactionAllowed
                ? vault.credential(for: accountID)
                : vault.credentialWithoutUserInteraction(for: accountID)
            guard let credential else {
                throw CodexAccountError.missingCredential(account.name)
            }
            return credential
        }
    }

    func updateSavedCredential(
        _ credential: Data,
        for accountID: UUID,
        interactionAllowed: Bool
    ) throws {
        try lock.withLock {
            let document = try documentStore.load()
            guard document.accounts.contains(where: { $0.id == accountID }) else {
                throw CodexAccountError.accountNotFound
            }
            if interactionAllowed {
                try vault.store(credential, for: accountID)
            } else {
                try vault.storeWithoutUserInteraction(credential, for: accountID)
            }
        }
    }

    @discardableResult
    func saveCurrentAccount() throws -> SavedAccount {
        try lock.withLock {
            guard let credential = try activeCredentialFile.read() else {
                throw CodexAccountError.noActiveCredential
            }
            guard let identity = AccountIdentityDecoder.identity(in: credential) else {
                throw CodexAccountError.accountIdentityUnavailable
            }
            var document = try documentStore.load()
            let timestamp = now()
            let account: SavedAccount
            if
                let index = document.accounts.firstIndex(where: {
                    $0.accountIdentifier == identity.identifier
                }) ?? document.activeAccountID.flatMap({ activeID in
                    document.accounts.firstIndex(where: { $0.id == activeID })
                })
            {
                document.accounts[index].name = identity.accountName
                document.accounts[index].lastUsedAt = timestamp
                document.accounts[index].accountIdentifier = identity.identifier
                document.activeAccountID = document.accounts[index].id
                account = document.accounts[index]
            } else {
                account = SavedAccount(
                    id: UUID(),
                    name: identity.accountName,
                    createdAt: timestamp,
                    lastUsedAt: timestamp,
                    accountIdentifier: identity.identifier
                )
                document.accounts.append(account)
                document.activeAccountID = account.id
            }
            try vault.store(credential, for: account.id)
            try documentStore.save(document)
            return account
        }
    }

    func activate(accountID: UUID) throws -> AccountTransition {
        try lock.withLock {
            var document = try documentStore.load()
            guard let index = document.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw CodexAccountError.accountNotFound
            }
            guard let targetCredential = try vault.credential(for: accountID) else {
                throw CodexAccountError.missingCredential(document.accounts[index].name)
            }
            let transaction = AccountTransition(
                previousCredential: try activeCredentialFile.read(), previousDocument: document
            )
            do {
                try saveActiveCredentialIfKnown(document)
                try activeCredentialFile.write(targetCredential)
                document.activeAccountID = accountID
                document.accounts[index].lastUsedAt = now()
                document.accounts[index].accountIdentifier = AccountIdentityDecoder.identity(
                    in: targetCredential
                )?.identifier
                try documentStore.save(document)
                return transaction
            } catch {
                try recover(transaction, after: error)
                throw error
            }
        }
    }

    func beginAddingAccount() throws -> AccountTransition {
        try lock.withLock {
            let document = try documentStore.load()
            let transaction = AccountTransition(
                previousCredential: try activeCredentialFile.read(), previousDocument: document
            )
            do {
                try saveActiveCredentialIfKnown(document)
                try activeCredentialFile.remove()
                var signedOutDocument = document
                signedOutDocument.activeAccountID = nil
                try documentStore.save(signedOutDocument)
                return transaction
            } catch {
                try recover(transaction, after: error)
                throw error
            }
        }
    }

    func rollback(_ transaction: AccountTransition) throws {
        try lock.withLock {
            let currentCredential = try activeCredentialFile.read()
            let currentDocument = try documentStore.load()
            do {
                try activeCredentialFile.restore(transaction.previousCredential)
                try documentStore.save(transaction.previousDocument)
            } catch {
                let rollbackError = error
                do {
                    try activeCredentialFile.restore(currentCredential)
                    try documentStore.save(currentDocument)
                } catch {
                    throw CodexAccountError.recoveryFailed(
                        "Rollback failed: \(rollbackError.localizedDescription) "
                            + "Restoring the switched state also failed: \(error.localizedDescription)"
                    )
                }
                throw rollbackError
            }
        }
    }

    func deleteAccount(_ accountID: UUID) throws {
        try lock.withLock {
            var document = try documentStore.load()
            let previousDocument = document
            document.accounts.removeAll { $0.id == accountID }
            if document.activeAccountID == accountID { document.activeAccountID = nil }
            try documentStore.save(document)
            do {
                try vault.deleteCredential(for: accountID)
            } catch {
                let deletionError = error
                do {
                    try documentStore.save(previousDocument)
                } catch {
                    throw CodexAccountError.recoveryFailed(
                        "Deleting the Keychain credential failed: \(deletionError.localizedDescription) "
                            + "Restoring the saved account list also failed: \(error.localizedDescription)"
                    )
                }
                throw deletionError
            }
        }
    }

    private func saveActiveCredentialIfKnown(_ document: SavedAccountsDocument) throws {
        guard
            let activeID = document.activeAccountID,
            document.accounts.contains(where: { $0.id == activeID }),
            let credential = try activeCredentialFile.read()
        else { return }
        try vault.store(credential, for: activeID)
    }

    private func recover(_ transaction: AccountTransition, after transitionError: Error) throws {
        do {
            try activeCredentialFile.restore(transaction.previousCredential)
            try documentStore.save(transaction.previousDocument)
        } catch {
            throw CodexAccountError.recoveryFailed(
                "The original operation failed: \(transitionError.localizedDescription) "
                    + "Restoring the previous state also failed: \(error.localizedDescription)"
            )
        }
    }

}
