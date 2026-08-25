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

    init(
        metadataURL: URL = CodexConfiguration.accountMetadataURL,
        authenticationURL: URL = CodexConfiguration.authenticationURL,
        vault: any AccountCredentialVault = KeychainAccountCredentialVault(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.metadataURL = metadataURL
        self.authenticationURL = authenticationURL
        self.vault = vault
        self.fileManager = fileManager
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
            let timestamp = now()
            let profile: CodexAccountProfile
            if
                let activeID = document.activeProfileID,
                let index = document.profiles.firstIndex(where: { $0.id == activeID })
            {
                document.profiles[index].name = name
                document.profiles[index].lastUsedAt = timestamp
                profile = document.profiles[index]
            } else {
                profile = CodexAccountProfile(
                    id: UUID(), name: name, createdAt: timestamp, lastUsedAt: timestamp
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
            document.profiles.removeAll { $0.id == profileID }
            if document.activeProfileID == profileID { document.activeProfileID = nil }
            try vault.deleteCredential(for: profileID)
            try saveDocument(document)
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
        let document = try JSONDecoder().decode(
            CodexAccountDocument.self, from: Data(contentsOf: metadataURL)
        )
        guard document.version == CodexAccountDocument.currentVersion else {
            throw CodexAccountError.unsupportedMetadataVersion(document.version)
        }
        return document
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
