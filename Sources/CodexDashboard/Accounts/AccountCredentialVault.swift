import Foundation
import LocalAuthentication
import Security

protocol AccountCredentialVault: Sendable {
    func credential(for accountID: UUID) throws -> Data?
    func credentialWithoutUserInteraction(for accountID: UUID) throws -> Data?
    func store(_ credential: Data, for accountID: UUID) throws
    func deleteCredential(for accountID: UUID) throws
}

struct KeychainAccountCredentialVault: AccountCredentialVault {
    private let service = "com.lawrenceawe.CodexDashboard.accounts"
    private let previousUserPresenceService =
        "com.lawrenceawe.CodexDashboard.accounts.user-presence-v1"
    private let authenticationPrompt = "Use Touch ID to switch Codex accounts"

    func credential(for accountID: UUID) throws -> Data? {
        try credential(for: accountID, interactionAllowed: true)
    }

    func credentialWithoutUserInteraction(for accountID: UUID) throws -> Data? {
        try credential(for: accountID, interactionAllowed: false)
    }

    private func credential(
        for accountID: UUID,
        interactionAllowed: Bool
    ) throws -> Data? {
        let currentCredential: Data?
        do {
            currentCredential = try readCredential(
                for: accountID,
                service: service,
                authenticationContext: interactionAllowed
                    ? nil
                    : authenticationContext(interactionAllowed: false)
            )
        } catch CodexAccountError.keychain(let status)
            where !interactionAllowed && Self.requiresUserInteraction(status)
        {
            return nil
        }
        if let credential = currentCredential {
            return credential
        }

        // A prior build stored credentials in the data-protection Keychain. Keep a
        // recovery path so a properly entitled build can move those secrets without
        // losing saved accounts. Ad-hoc local builds cannot access that Keychain and
        // report errSecMissingEntitlement, which must not break the ordinary vault.
        let previousCredential: Data?
        do {
            previousCredential = try readCredential(
                for: accountID,
                service: previousUserPresenceService,
                authenticationContext: authenticationContext(
                    interactionAllowed: interactionAllowed
                )
            )
        } catch CodexAccountError.keychain(let status) where status == errSecMissingEntitlement {
            return nil
        } catch CodexAccountError.keychain(let status)
            where !interactionAllowed && Self.requiresUserInteraction(status)
        {
            return nil
        }
        guard let previousCredential else { return nil }
        try store(previousCredential, for: accountID)
        deletePreviousCredentialWithoutPrompt(for: accountID)
        return previousCredential
    }

    private static func requiresUserInteraction(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
    }

    func store(_ credential: Data, for accountID: UUID) throws {
        let updateQuery = baseQuery(for: accountID, service: service)
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

        var addition = baseQuery(for: accountID, service: service)
        addition[kSecValueData as String] = credential
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CodexAccountError.keychain(addStatus) }
    }

    func deleteCredential(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: accountID, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexAccountError.keychain(status)
        }
        deletePreviousCredentialWithoutPrompt(for: accountID)
    }

    private func readCredential(
        for accountID: UUID,
        service: String,
        authenticationContext: LAContext?
    ) throws -> Data? {
        var query = baseQuery(for: accountID, service: service)
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

    private func deletePreviousCredentialWithoutPrompt(for accountID: UUID) {
        var query = baseQuery(for: accountID, service: previousUserPresenceService)
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

    private func baseQuery(for accountID: UUID, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }
}
