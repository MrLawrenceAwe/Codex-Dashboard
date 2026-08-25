import Foundation
import LocalAuthentication
import Security

protocol AccountCredentialVault: Sendable {
    func credential(for profileID: UUID) throws -> Data?
    func store(_ credential: Data, for profileID: UUID) throws
    func deleteCredential(for profileID: UUID) throws
}

struct KeychainAccountCredentialVault: AccountCredentialVault {
    private let protectedService = "com.lawrenceawe.CodexDashboard.accounts.user-presence-v1"
    private let legacyService = "com.lawrenceawe.CodexDashboard.accounts"
    private let authenticationPrompt = "Use Touch ID to switch Codex accounts"

    func credential(for profileID: UUID) throws -> Data? {
        if let credential = try readCredential(
            for: profileID,
            service: protectedService,
            promptForUserPresence: true
        ) {
            return credential
        }

        // Existing installations used an ordinary generic-password item. Read it once
        // using its original access policy, then move it into the user-presence vault.
        guard let legacyCredential = try readCredential(
            for: profileID,
            service: legacyService,
            promptForUserPresence: false
        ) else { return nil }
        try store(legacyCredential, for: profileID)
        deleteLegacyCredentialWithoutPrompt(for: profileID)
        return legacyCredential
    }

    func store(_ credential: Data, for profileID: UUID) throws {
        var updateQuery = baseQuery(for: profileID, service: protectedService)
        updateQuery[kSecUseAuthenticationContext as String] = authenticationContext()
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            [kSecValueData as String: credential] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            deleteLegacyCredentialWithoutPrompt(for: profileID)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CodexAccountError.keychain(updateStatus)
        }

        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessControlError
        ) else {
            let detail = accessControlError?.takeRetainedValue().localizedDescription
                ?? "Keychain rejected the access-control policy."
            throw CodexAccountError.keychainAccessControl(detail)
        }

        var addition = baseQuery(for: profileID, service: protectedService)
        addition[kSecValueData as String] = credential
        addition[kSecAttrAccessControl as String] = accessControl
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CodexAccountError.keychain(addStatus) }
        deleteLegacyCredentialWithoutPrompt(for: profileID)
    }

    func deleteCredential(for profileID: UUID) throws {
        var protectedQuery = baseQuery(for: profileID, service: protectedService)
        protectedQuery[kSecUseAuthenticationContext as String] = authenticationContext()
        let protectedStatus = SecItemDelete(protectedQuery as CFDictionary)
        guard protectedStatus == errSecSuccess || protectedStatus == errSecItemNotFound else {
            throw CodexAccountError.keychain(protectedStatus)
        }

        let legacyStatus = SecItemDelete(
            baseQuery(for: profileID, service: legacyService) as CFDictionary
        )
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw CodexAccountError.keychain(legacyStatus)
        }
    }

    private func readCredential(
        for profileID: UUID,
        service: String,
        promptForUserPresence: Bool
    ) throws -> Data? {
        var query = baseQuery(for: profileID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if promptForUserPresence {
            query[kSecUseAuthenticationContext as String] = authenticationContext()
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CodexAccountError.keychain(status) }
        return result as? Data
    }

    private func deleteLegacyCredentialWithoutPrompt(for profileID: UUID) {
        var query = baseQuery(for: profileID, service: legacyService)
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
