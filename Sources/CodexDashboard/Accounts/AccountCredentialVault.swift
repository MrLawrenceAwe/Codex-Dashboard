import Foundation
import LocalAuthentication
import Security

protocol AccountCredentialVault: Sendable {
    func credential(for profileID: UUID) throws -> Data?
    func store(_ credential: Data, for profileID: UUID) throws
    func deleteCredential(for profileID: UUID) throws
}

struct KeychainAccountCredentialVault: AccountCredentialVault {
    private let service = "com.lawrenceawe.CodexDashboard.accounts"
    private let previousUserPresenceService =
        "com.lawrenceawe.CodexDashboard.accounts.user-presence-v1"
    private let authenticationPrompt = "Use Touch ID to switch Codex accounts"

    func credential(for profileID: UUID) throws -> Data? {
        if let credential = try readCredential(
            for: profileID,
            service: service,
            authenticationContext: nil
        ) {
            return credential
        }

        // A prior build stored credentials in the data-protection Keychain. Keep a
        // recovery path so a properly entitled build can move those secrets without
        // losing saved accounts. Ad-hoc local builds cannot access that Keychain and
        // report errSecMissingEntitlement, which must not break the ordinary vault.
        let previousCredential: Data?
        do {
            previousCredential = try readCredential(
                for: profileID,
                service: previousUserPresenceService,
                authenticationContext: authenticationContext()
            )
        } catch CodexAccountError.keychain(let status) where status == errSecMissingEntitlement {
            return nil
        }
        guard let previousCredential else { return nil }
        try store(previousCredential, for: profileID)
        deletePreviousCredentialWithoutPrompt(for: profileID)
        return previousCredential
    }

    func store(_ credential: Data, for profileID: UUID) throws {
        let updateQuery = baseQuery(for: profileID, service: service)
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            [kSecValueData as String: credential] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CodexAccountError.keychain(updateStatus)
        }

        var addition = baseQuery(for: profileID, service: service)
        addition[kSecValueData as String] = credential
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CodexAccountError.keychain(addStatus) }
    }

    func deleteCredential(for profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: profileID, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexAccountError.keychain(status)
        }
        deletePreviousCredentialWithoutPrompt(for: profileID)
    }

    private func readCredential(
        for profileID: UUID,
        service: String,
        authenticationContext: LAContext?
    ) throws -> Data? {
        var query = baseQuery(for: profileID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CodexAccountError.keychain(status) }
        return result as? Data
    }

    private func deletePreviousCredentialWithoutPrompt(for profileID: UUID) {
        var query = baseQuery(for: profileID, service: previousUserPresenceService)
        query[kSecUseAuthenticationContext as String] = authenticationContext(
            interactionAllowed: false
        )
        _ = SecItemDelete(query as CFDictionary)
    }

    private func authenticationContext(interactionAllowed: Bool = true) -> LAContext {
        let context = LAContext()
        context.localizedReason = authenticationPrompt
        context.interactionNotAllowed = !interactionAllowed
        return context
    }

    private func baseQuery(for profileID: UUID, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }
}
