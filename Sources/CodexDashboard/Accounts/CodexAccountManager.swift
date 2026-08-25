import Foundation

struct AccountTransition: Sendable {
    fileprivate let previousCredential: Data?
    fileprivate let previousDocument: SavedAccountsDocument
}

final class CodexAccountManager: @unchecked Sendable {
    private let metadataURL: URL
    private let authenticationURL: URL
    private let vault: any AccountCredentialVault
    private let fileManager: FileManager
    private let now: () -> Date
    private let lock = NSLock()
    let usageCacheStore: UsageCache

    init(
        metadataURL: URL = CodexConfiguration.accountMetadataURL,
        authenticationURL: URL = CodexConfiguration.authenticationURL,
        vault: any AccountCredentialVault = KeychainAccountCredentialVault(),
        fileManager: FileManager = .default,
        usageCacheStore: UsageCache? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.metadataURL = metadataURL
        self.authenticationURL = authenticationURL
        self.vault = vault
        self.fileManager = fileManager
        self.usageCacheStore = usageCacheStore ?? UsageCache(
            cacheURL: metadataURL.deletingLastPathComponent()
                .appendingPathComponent("account-usage.json"),
            fileManager: fileManager
        )
        self.now = now
    }

    func document() throws -> SavedAccountsDocument {
        try lock.withLock { try loadDocument() }
    }

    @discardableResult
    func saveCurrentAccount(named rawName: String) throws -> SavedAccount {
        try lock.withLock {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CodexAccountError.accountNameRequired }
            guard let credential = try activeCredential() else {
                throw CodexAccountError.noActiveCredential
            }
            var document = try loadDocument()
            let accountIdentifier = Self.accountIdentity(in: credential)?.identifier
            let timestamp = now()
            let account: SavedAccount
            if
                let index = document.accounts.firstIndex(where: {
                    accountIdentifier != nil && $0.accountIdentifier == accountIdentifier
                }) ?? document.activeAccountID.flatMap({ activeID in
                    document.accounts.firstIndex(where: { $0.id == activeID })
                })
            {
                document.accounts[index].name = name
                document.accounts[index].lastUsedAt = timestamp
                document.accounts[index].accountIdentifier = accountIdentifier
                document.activeAccountID = document.accounts[index].id
                account = document.accounts[index]
            } else {
                account = SavedAccount(
                    id: UUID(),
                    name: name,
                    createdAt: timestamp,
                    lastUsedAt: timestamp,
                    accountIdentifier: accountIdentifier
                )
                document.accounts.append(account)
                document.activeAccountID = account.id
            }
            try vault.store(credential, for: account.id)
            try saveDocument(document)
            return account
        }
    }

    func activate(accountID: UUID) throws -> AccountTransition {
        try lock.withLock {
            var document = try loadDocument()
            guard let index = document.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw CodexAccountError.accountNotFound
            }
            guard let targetCredential = try vault.credential(for: accountID) else {
                throw CodexAccountError.missingCredential(document.accounts[index].name)
            }
            let transaction = AccountTransition(
                previousCredential: try activeCredential(), previousDocument: document
            )
            do {
                try saveActiveCredentialIfKnown(document)
                try writeActiveCredential(targetCredential)
                document.activeAccountID = accountID
                document.accounts[index].lastUsedAt = now()
                document.accounts[index].accountIdentifier = Self.accountIdentity(
                    in: targetCredential
                )?.identifier
                try saveDocument(document)
                return transaction
            } catch {
                try? restoreActiveCredential(transaction.previousCredential)
                try? saveDocument(transaction.previousDocument)
                throw error
            }
        }
    }

    func beginAddingAccount() throws -> AccountTransition {
        try lock.withLock {
            let document = try loadDocument()
            let transaction = AccountTransition(
                previousCredential: try activeCredential(), previousDocument: document
            )
            do {
                try saveActiveCredentialIfKnown(document)
                if fileManager.fileExists(atPath: authenticationURL.path) {
                    try fileManager.removeItem(at: authenticationURL)
                }
                var signedOutDocument = document
                signedOutDocument.activeAccountID = nil
                try saveDocument(signedOutDocument)
                return transaction
            } catch {
                try? restoreActiveCredential(transaction.previousCredential)
                try? saveDocument(transaction.previousDocument)
                throw error
            }
        }
    }

    func rollback(_ transaction: AccountTransition) throws {
        try lock.withLock {
            try restoreActiveCredential(transaction.previousCredential)
            try saveDocument(transaction.previousDocument)
        }
    }

    func deleteAccount(_ accountID: UUID) throws {
        try lock.withLock {
            var document = try loadDocument()
            let previousDocument = document
            document.accounts.removeAll { $0.id == accountID }
            if document.activeAccountID == accountID { document.activeAccountID = nil }
            try saveDocument(document)
            do {
                try vault.deleteCredential(for: accountID)
            } catch {
                try? saveDocument(previousDocument)
                throw error
            }
        }
    }

    private func activeCredential() throws -> Data? {
        guard fileManager.fileExists(atPath: authenticationURL.path) else { return nil }
        let data = try Data(contentsOf: authenticationURL)
        guard !data.isEmpty else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw CodexAccountError.invalidCredential
        }
        return data
    }

    private func saveActiveCredentialIfKnown(_ document: SavedAccountsDocument) throws {
        guard
            let activeID = document.activeAccountID,
            document.accounts.contains(where: { $0.id == activeID }),
            let credential = try activeCredential()
        else { return }
        try vault.store(credential, for: activeID)
    }

    private func writeActiveCredential(_ credential: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: credential)) is [String: Any] else {
            throw CodexAccountError.invalidCredential
        }
        try fileManager.createDirectory(
            at: authenticationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try credential.write(to: authenticationURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: authenticationURL.path
        )
    }

    private func restoreActiveCredential(_ credential: Data?) throws {
        if let credential {
            try writeActiveCredential(credential)
        } else if fileManager.fileExists(atPath: authenticationURL.path) {
            try fileManager.removeItem(at: authenticationURL)
        }
    }

    private func loadDocument() throws -> SavedAccountsDocument {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return SavedAccountsDocument()
        }
        let data = try Data(contentsOf: metadataURL)
        let storedVersion = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }?["version"] as? Int
        let migration = try AccountDocumentMigration.decode(
            data,
            version: storedVersion ?? 0,
            accountIdentifier: { accountID in
                (try? vault.credential(for: accountID))
                    .flatMap { Self.accountIdentity(in: $0)?.identifier }
            }
        )
        var document = migration.document
        let original = document
        reconcileActiveAccount(in: &document, allowNameFallback: migration.requiresNameFallback)
        if document != original || migration.requiresNameFallback { try saveDocument(document) }
        return document
    }

    private func reconcileActiveAccount(
        in document: inout SavedAccountsDocument,
        allowNameFallback: Bool
    ) {
        guard let credential = try? activeCredential() else {
            document.activeAccountID = nil
            return
        }
        guard let identity = Self.accountIdentity(in: credential) else { return }
        if let account = document.accounts.first(where: {
            $0.accountIdentifier == identity.identifier
        }) {
            document.activeAccountID = account.id
            return
        }
        if allowNameFallback, let displayName = identity.displayName {
            let candidates = document.accounts.indices.filter {
                document.accounts[$0].accountIdentifier == nil
                    && Self.accountName(document.accounts[$0].name, matches: displayName)
            }
            if candidates.count == 1, let index = candidates.first {
                document.accounts[index].accountIdentifier = identity.identifier
                document.activeAccountID = document.accounts[index].id
                return
            }
        }
        document.activeAccountID = nil
    }

    private static func accountIdentity(in credential: Data) -> AccountIdentity? {
        guard
            let object = try? JSONSerialization.jsonObject(with: credential),
            let root = object as? [String: Any],
            let tokens = root["tokens"] as? [String: Any]
        else { return nil }
        let directAccountID = tokens["account_id"] as? String
        guard let idToken = tokens["id_token"] as? String else {
            return directAccountID.flatMap {
                $0.isEmpty ? nil : AccountIdentity(identifier: $0, displayName: nil)
            }
        }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return directAccountID.flatMap {
                $0.isEmpty ? nil : AccountIdentity(identifier: $0, displayName: nil)
            }
        }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let payloadData = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
            let authentication = claims["https://api.openai.com/auth"] as? [String: Any],
            let accountID = directAccountID
                ?? authentication["chatgpt_account_id"] as? String,
            !accountID.isEmpty
        else { return nil }
        return AccountIdentity(identifier: accountID, displayName: claims["name"] as? String)
    }

    private static func accountName(_ accountName: String, matches displayName: String) -> Bool {
        let accountWords = normalizedWords(in: accountName)
        let displayWords = normalizedWords(in: displayName)
        guard !accountWords.isEmpty, !displayWords.isEmpty else { return false }
        return accountWords == displayWords
            || (accountWords.count == 1 && displayWords.contains(accountWords[0]))
    }

    private static func normalizedWords(in value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func saveDocument(_ document: SavedAccountsDocument) throws {
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: metadataURL, options: [.atomic])
    }
}

private struct AccountIdentity {
    let identifier: String
    let displayName: String?
}
