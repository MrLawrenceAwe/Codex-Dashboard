import Foundation

struct CodexAccountTransaction: Sendable {
    fileprivate let previousCredential: Data?
    fileprivate let previousDocument: CodexAccountDocument
}

final class CodexAccountManager: @unchecked Sendable {
    private let metadataURL: URL
    private let authenticationURL: URL
    private let vault: any AccountCredentialVault
    private let fileManager: FileManager
    private let now: () -> Date
    private let lock = NSLock()
    let usageCacheStore: CodexAccountUsageCacheStore

    init(
        metadataURL: URL = CodexConfiguration.accountMetadataURL,
        authenticationURL: URL = CodexConfiguration.authenticationURL,
        vault: any AccountCredentialVault = KeychainAccountCredentialVault(),
        fileManager: FileManager = .default,
        usageCacheStore: CodexAccountUsageCacheStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.metadataURL = metadataURL
        self.authenticationURL = authenticationURL
        self.vault = vault
        self.fileManager = fileManager
        self.usageCacheStore = usageCacheStore ?? CodexAccountUsageCacheStore(
            cacheURL: metadataURL.deletingLastPathComponent()
                .appendingPathComponent("account-usage.json"),
            fileManager: fileManager
        )
        self.now = now
    }

    func document() throws -> CodexAccountDocument {
        try lock.withLock { try loadDocument() }
    }

    @discardableResult
    func saveCurrentAccount(named rawName: String) throws -> CodexAccountProfile {
        try lock.withLock {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CodexAccountError.accountNameRequired }
            guard let credential = try activeCredential() else {
                throw CodexAccountError.noActiveCredential
            }
            var document = try loadDocument()
            let accountIdentifier = Self.accountIdentity(in: credential)?.identifier
            let timestamp = now()
            let profile: CodexAccountProfile
            if
                let index = document.profiles.firstIndex(where: {
                    accountIdentifier != nil && $0.accountIdentifier == accountIdentifier
                }) ?? document.activeProfileID.flatMap({ activeID in
                    document.profiles.firstIndex(where: { $0.id == activeID })
                })
            {
                document.profiles[index].name = name
                document.profiles[index].lastUsedAt = timestamp
                document.profiles[index].accountIdentifier = accountIdentifier
                document.activeProfileID = document.profiles[index].id
                profile = document.profiles[index]
            } else {
                profile = CodexAccountProfile(
                    id: UUID(),
                    name: name,
                    createdAt: timestamp,
                    lastUsedAt: timestamp,
                    accountIdentifier: accountIdentifier
                )
                document.profiles.append(profile)
                document.activeProfileID = profile.id
            }
            try vault.store(credential, for: profile.id)
            try saveDocument(document)
            return profile
        }
    }

    func activate(profileID: UUID) throws -> CodexAccountTransaction {
        try lock.withLock {
            var document = try loadDocument()
            guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw CodexAccountError.invalidProfile
            }
            guard let targetCredential = try vault.credential(for: profileID) else {
                throw CodexAccountError.missingCredential(document.profiles[index].name)
            }
            let transaction = CodexAccountTransaction(
                previousCredential: try activeCredential(), previousDocument: document
            )
            do {
                try saveActiveCredentialIfKnown(document)
                try writeActiveCredential(targetCredential)
                document.activeProfileID = profileID
                document.profiles[index].lastUsedAt = now()
                document.profiles[index].accountIdentifier = Self.accountIdentity(
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

    func beginAddingAccount() throws -> CodexAccountTransaction {
        try lock.withLock {
            let document = try loadDocument()
            let transaction = CodexAccountTransaction(
                previousCredential: try activeCredential(), previousDocument: document
            )
            do {
                try saveActiveCredentialIfKnown(document)
                if fileManager.fileExists(atPath: authenticationURL.path) {
                    try fileManager.removeItem(at: authenticationURL)
                }
                var signedOutDocument = document
                signedOutDocument.activeProfileID = nil
                try saveDocument(signedOutDocument)
                return transaction
            } catch {
                try? restoreActiveCredential(transaction.previousCredential)
                try? saveDocument(transaction.previousDocument)
                throw error
            }
        }
    }

    func rollback(_ transaction: CodexAccountTransaction) throws {
        try lock.withLock {
            try restoreActiveCredential(transaction.previousCredential)
            try saveDocument(transaction.previousDocument)
        }
    }

    func deleteProfile(_ profileID: UUID) throws {
        try lock.withLock {
            var document = try loadDocument()
            let previousDocument = document
            document.profiles.removeAll { $0.id == profileID }
            if document.activeProfileID == profileID { document.activeProfileID = nil }
            try saveDocument(document)
            do {
                try vault.deleteCredential(for: profileID)
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

    private func saveActiveCredentialIfKnown(_ document: CodexAccountDocument) throws {
        guard
            let activeID = document.activeProfileID,
            document.profiles.contains(where: { $0.id == activeID }),
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

    private func loadDocument() throws -> CodexAccountDocument {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return CodexAccountDocument()
        }
        let data = try Data(contentsOf: metadataURL)
        let storedVersion = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }?["version"] as? Int
        var document: CodexAccountDocument
        switch storedVersion {
        case CodexAccountDocument.currentVersion:
            document = try JSONDecoder().decode(CodexAccountDocument.self, from: data)
        case 2:
            document = try JSONDecoder().decode(CodexAccountDocument.self, from: data)
            document.version = CodexAccountDocument.currentVersion
        case 1:
            let previous = try JSONDecoder().decode(LegacyAccountDocument.self, from: data)
            document = CodexAccountDocument(
                profiles: previous.profiles.map { profile in
                    CodexAccountProfile(
                        id: profile.id,
                        name: profile.name,
                        createdAt: profile.createdAt,
                        lastUsedAt: profile.lastUsedAt,
                        accountIdentifier: (try? vault.credential(for: profile.id))
                            .flatMap { Self.accountIdentity(in: $0)?.identifier }
                    )
                },
                activeProfileID: previous.activeProfileID
            )
        default:
            throw CodexAccountError.unsupportedMetadataVersion(storedVersion ?? 0)
        }
        let original = document
        reconcileActiveProfile(in: &document, allowNameFallback: storedVersion != 3)
        if document != original || storedVersion != 3 { try saveDocument(document) }
        return document
    }

    private func reconcileActiveProfile(
        in document: inout CodexAccountDocument,
        allowNameFallback: Bool
    ) {
        guard let credential = try? activeCredential() else {
            document.activeProfileID = nil
            return
        }
        guard let identity = Self.accountIdentity(in: credential) else { return }
        if let profile = document.profiles.first(where: {
            $0.accountIdentifier == identity.identifier
        }) {
            document.activeProfileID = profile.id
            return
        }
        if allowNameFallback, let displayName = identity.displayName {
            let candidates = document.profiles.indices.filter {
                document.profiles[$0].accountIdentifier == nil
                    && Self.profileName(document.profiles[$0].name, matches: displayName)
            }
            if candidates.count == 1, let index = candidates.first {
                document.profiles[index].accountIdentifier = identity.identifier
                document.activeProfileID = document.profiles[index].id
                return
            }
        }
        document.activeProfileID = nil
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

    private static func profileName(_ profileName: String, matches displayName: String) -> Bool {
        let profileWords = normalizedWords(in: profileName)
        let displayWords = normalizedWords(in: displayName)
        guard !profileWords.isEmpty, !displayWords.isEmpty else { return false }
        return profileWords == displayWords
            || (profileWords.count == 1 && displayWords.contains(profileWords[0]))
    }

    private static func normalizedWords(in value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func saveDocument(_ document: CodexAccountDocument) throws {
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

private struct LegacyAccountProfile: Decodable {
    let id: UUID
    let name: String
    let createdAt: Date
    let lastUsedAt: Date
}

private struct LegacyAccountDocument: Decodable {
    let profiles: [LegacyAccountProfile]
    let activeProfileID: UUID?
}
