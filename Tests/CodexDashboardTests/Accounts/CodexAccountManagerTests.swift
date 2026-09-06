import Foundation
import XCTest

@testable import CodexDashboard

private final class MemoryAccountCredentialVault: AccountCredentialVault, @unchecked Sendable {
    enum TestError: Error { case deletionFailed }

    private var values: [UUID: Data] = [:]
    private var deletionCount = 0
    private var interactiveReadCount = 0
    private var backgroundReadCount = 0
    private var interactiveStoreCount = 0
    private var backgroundStoreCount = 0
    private var deletionShouldFail = false
    private var beforeDeletionFailure: (() -> Void)?
    private let lock = NSLock()

    func credential(for accountID: UUID) -> Data? {
        lock.withLock {
            interactiveReadCount += 1
            return values[accountID]
        }
    }

    func credentialWithoutUserInteraction(for accountID: UUID) -> Data? {
        lock.withLock {
            backgroundReadCount += 1
            return values[accountID]
        }
    }

    func store(_ credential: Data, for accountID: UUID) {
        lock.withLock {
            interactiveStoreCount += 1
            values[accountID] = credential
        }
    }

    func storeWithoutUserInteraction(_ credential: Data, for accountID: UUID) {
        lock.withLock {
            backgroundStoreCount += 1
            values[accountID] = credential
        }
    }

    func deleteCredential(for accountID: UUID) throws {
        try lock.withLock {
            if deletionShouldFail {
                beforeDeletionFailure?()
                throw TestError.deletionFailed
            }
            deletionCount += 1
            values.removeValue(forKey: accountID)
        }
    }

    var deleteCallCount: Int { lock.withLock { deletionCount } }
    var interactiveReads: Int { lock.withLock { interactiveReadCount } }
    var backgroundReads: Int { lock.withLock { backgroundReadCount } }
    var interactiveStores: Int { lock.withLock { interactiveStoreCount } }
    var backgroundStores: Int { lock.withLock { backgroundStoreCount } }

    func failDeletion(beforeFailure: (() -> Void)? = nil) {
        lock.withLock {
            deletionShouldFail = true
            beforeDeletionFailure = beforeFailure
        }
    }
}

final class CodexAccountManagerTests: XCTestCase {
    private var directory: URL!
    private var authenticationURL: URL!
    private var metadataURL: URL!
    private var vault: MemoryAccountCredentialVault!
    private var manager: CodexAccountManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAccountManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        authenticationURL = directory.appendingPathComponent(".codex/auth.json")
        metadataURL = directory.appendingPathComponent("support/accounts.json")
        try FileManager.default.createDirectory(
            at: authenticationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        vault = MemoryAccountCredentialVault()
        manager = CodexAccountManager(
            metadataURL: metadataURL,
            authenticationURL: authenticationURL,
            vault: vault,
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSavesCurrentCredentialAndMetadataSeparately() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)

        let account = try manager.saveCurrentAccount()
        let document = try manager.loadDocument()

        XCTAssertEqual(account.name, "Personal")
        XCTAssertEqual(document.accounts, [account])
        XCTAssertEqual(document.activeAccountID, account.id)
        XCTAssertEqual(vault.credential(for: account.id), credential)
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertNotNil(metadata["accounts"])
        XCTAssertEqual(metadata["activeAccountID"] as? String, account.id.uuidString)
        XCTAssertNil(metadata["profiles"])
        XCTAssertNil(metadata["activeProfileID"])
        XCTAssertFalse(String(data: try Data(contentsOf: metadataURL), encoding: .utf8)!.contains("secret"))
    }

    func testSwitchSavesRotatedActiveCredentialAndRollbackRestoresIt() throws {
        let personal = credential(
            accountID: "account-personal", name: "Personal", accessToken: "personal-original"
        )
        try personal.write(to: authenticationURL)
        let personalAccount = try manager.saveCurrentAccount()

        _ = try manager.beginAddingAccount()
        let work = credential(
            accountID: "account-work", name: "Work", accessToken: "work-original"
        )
        try work.write(to: authenticationURL)
        let workAccount = try manager.saveCurrentAccount()

        let rotatedWork = credential(
            accountID: "account-work", name: "Work", accessToken: "work-rotated"
        )
        try rotatedWork.write(to: authenticationURL)
        let transaction = try manager.activate(accountID: personalAccount.id)

        XCTAssertEqual(try Data(contentsOf: authenticationURL), personal)
        XCTAssertEqual(vault.credential(for: workAccount.id), rotatedWork)
        XCTAssertEqual(try manager.loadDocument().activeAccountID, personalAccount.id)

        try manager.rollback(transaction)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), rotatedWork)
        XCTAssertEqual(try manager.loadDocument().activeAccountID, workAccount.id)
    }

    func testBeginAddingAccountSignsOutAndCanRollback() throws {
        let credential = credential(accountID: "account-current", name: "Current")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()

        let transaction = try manager.beginAddingAccount()
        XCTAssertFalse(FileManager.default.fileExists(atPath: authenticationURL.path))
        XCTAssertNil(try manager.loadDocument().activeAccountID)

        try manager.rollback(transaction)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), credential)
        XCTAssertEqual(try manager.loadDocument().activeAccountID, account.id)
    }

    func testUnsupportedMetadataVersionIsNotOverwritten() throws {
        let unsupportedDocument = Data(
            #"{"version":99,"profiles":[],"activeProfileID":null}"#.utf8
        )
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try unsupportedDocument.write(to: metadataURL)
        try credential(accountID: "account-current", name: "Current")
            .write(to: authenticationURL)

        XCTAssertThrowsError(try manager.beginAddingAccount()) { error in
            guard case CodexAccountError.unsupportedMetadataVersion(99) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), unsupportedDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: authenticationURL.path))
    }

    func testDeleteDoesNotRemoveCredentialWhenMetadataCannotBeSaved() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()
        let supportDirectory = metadataURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: supportDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: supportDirectory.path
            )
        }

        XCTAssertThrowsError(try manager.deleteAccount(account.id))
        XCTAssertEqual(vault.deleteCallCount, 0)
        XCTAssertEqual(vault.credential(for: account.id), credential)
    }

    func testDeleteRestoresMetadataWhenCredentialDeletionFails() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()
        vault.failDeletion()

        XCTAssertThrowsError(try manager.deleteAccount(account.id)) { error in
            XCTAssertTrue(error is MemoryAccountCredentialVault.TestError)
        }
        XCTAssertEqual(try manager.loadDocument().accounts, [account])
        XCTAssertEqual(vault.credential(for: account.id), credential)
    }

    func testDeleteReportsUnsafeRecoveryWhenMetadataCannotBeRestored() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()
        let supportDirectory = metadataURL.deletingLastPathComponent()
        vault.failDeletion {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: supportDirectory.path
            )
        }
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: supportDirectory.path
            )
        }

        XCTAssertThrowsError(try manager.deleteAccount(account.id)) { error in
            guard case CodexAccountError.recoveryFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(vault.credential(for: account.id), credential)
    }

    func testReconcilesStaleActiveAccountWithCurrentCodexAccount() throws {
        let lawrenceCredential = credential(accountID: "account-lawrence", name: "Lawrence")
        try lawrenceCredential.write(to: authenticationURL)
        let lawrence = try manager.saveCurrentAccount()

        _ = try manager.beginAddingAccount()
        let oluwatoyinCredential = credential(
            accountID: "account-oluwatoyin", name: "Oluwatoyin"
        )
        try oluwatoyinCredential.write(to: authenticationURL)
        let oluwatoyin = try manager.saveCurrentAccount()

        var metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadataURL)
        ) as! [String: Any]
        metadata["activeAccountID"] = lawrence.id.uuidString
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

        let document = try manager.loadDocument()

        XCTAssertEqual(document.activeAccountID, oluwatoyin.id)
    }

    func testIdentityUsesDirectAccountIDWhenIDTokenClaimsCannotBeDecoded() throws {
        let credential = Data(
            #"{"tokens":{"account_id":"account-lawrence","id_token":"header.invalid.signature"}}"#.utf8
        )

        let identity = try XCTUnwrap(AccountIdentityDecoder.identity(in: credential))

        XCTAssertEqual(identity.identifier, "account-lawrence")
        XCTAssertNil(identity.displayName)
    }

    func testNormalizesProfileDisplayNameWhitespace() throws {
        let credential = credential(accountID: "account-lawrence", name: "  Lawrence   Awe\n")

        let identity = try XCTUnwrap(AccountIdentityDecoder.identity(in: credential))

        XCTAssertEqual(identity.accountName, "Lawrence Awe")
    }

    func testUsesAccountEmailWhenDisplayNameIsUnavailable() throws {
        let credential = credential(
            accountID: "account-personal",
            email: "lawrence@example.com"
        )
        try credential.write(to: authenticationURL)

        let account = try manager.saveCurrentAccount()

        XCTAssertEqual(account.name, "lawrence@example.com")
    }

    func testUsageCredentialReadNeverRequestsInteractiveVaultAccess() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()

        let savedCredential = try manager.savedCredential(for: account.id, interactionAllowed: false)

        XCTAssertEqual(savedCredential, credential)
        XCTAssertEqual(vault.interactiveReads, 0)
        XCTAssertEqual(vault.backgroundReads, 1)
    }

    func testManualCredentialRecoveryAllowsInteractiveVaultAccessWithoutSwitching() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()

        let savedCredential = try manager.savedCredential(
            for: account.id, interactionAllowed: true
        )

        XCTAssertEqual(savedCredential, credential)
        XCTAssertEqual(vault.interactiveReads, 1)
        XCTAssertEqual(vault.backgroundReads, 0)
        XCTAssertEqual(try manager.loadDocument().activeAccountID, account.id)
    }

    func testUsageCredentialUpdateNeverRequestsInteractiveVaultAccess() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()
        let refreshedCredential = self.credential(
            accountID: "account-personal",
            name: "Personal",
            accessToken: "refreshed"
        )

        try manager.updateSavedCredential(
            refreshedCredential,
            for: account.id,
            interactionAllowed: false
        )

        XCTAssertEqual(vault.interactiveStores, 1)
        XCTAssertEqual(vault.backgroundStores, 1)
        XCTAssertEqual(vault.credential(for: account.id), refreshedCredential)
    }

    func testLoadReplacesStoredCustomNameWithAuthenticatedAccountName() throws {
        let credential = credential(accountID: "account-personal", name: "Lawrence Awe")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()
        let legacy: [String: Any] = [
            "version": 3,
            "profiles": [[
                "id": account.id.uuidString,
                "name": "My custom label",
                "createdAt": account.createdAt.timeIntervalSinceReferenceDate,
                "lastUsedAt": account.lastUsedAt.timeIntervalSinceReferenceDate,
            ]],
            "activeProfileID": account.id.uuidString,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadataURL)

        let reloaded = try manager.loadDocument()

        XCTAssertEqual(reloaded.accounts.first(where: { $0.id == account.id })?.name, "Lawrence Awe")
    }

    func testMigratesV5AccountNamesUsingNormalizedAuthenticatedProfileName() throws {
        let credential = credential(accountID: "account-personal", name: "Lawrence  Awe")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()
        var document = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadataURL)
        ) as! [String: Any]
        document["version"] = 5
        try JSONSerialization.data(withJSONObject: document).write(to: metadataURL)

        let reloaded = try manager.loadDocument()

        XCTAssertEqual(reloaded.version, SavedAccountsDocument.currentVersion)
        XCTAssertEqual(reloaded.accounts.first(where: { $0.id == account.id })?.name, "Lawrence Awe")
    }

    func testMigratesV4ProfileKeysToCurrentAccountKeys() throws {
        let credential = credential(accountID: "account-personal", name: "Personal")
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount()
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        legacy["version"] = 4
        legacy["profiles"] = legacy.removeValue(forKey: "accounts")
        legacy["activeProfileID"] = legacy.removeValue(forKey: "activeAccountID")
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadataURL)

        XCTAssertEqual(try manager.loadDocument().activeAccountID, account.id)

        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertEqual(migrated["version"] as? Int, SavedAccountsDocument.currentVersion)
        XCTAssertNotNil(migrated["accounts"])
        XCTAssertNotNil(migrated["activeAccountID"])
        XCTAssertNil(migrated["profiles"])
        XCTAssertNil(migrated["activeProfileID"])
    }

    func testSavingRequiresAnAuthenticatedAccountIdentity() throws {
        try Data(#"{"tokens":{"access_token":"secret"}}"#.utf8)
            .write(to: authenticationURL)

        XCTAssertThrowsError(try manager.saveCurrentAccount()) { error in
            guard case CodexAccountError.accountIdentityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMigratesExistingAccountsAndReconcilesTheirAccountIdentifiers() throws {
        let lawrenceID = UUID()
        let oluwatoyinID = UUID()
        vault.store(
            credential(accountID: "account-lawrence", name: "Lawrence"),
            for: lawrenceID
        )
        vault.store(
            credential(accountID: "account-oluwatoyin", name: "Oluwatoyin"),
            for: oluwatoyinID
        )
        try credential(accountID: "account-oluwatoyin", name: "Oluwatoyin")
            .write(to: authenticationURL)
        let legacy: [String: Any] = [
            "version": 1,
            "profiles": [
                ["id": lawrenceID.uuidString, "name": "Lawrence", "createdAt": 1.0, "lastUsedAt": 1.0],
                ["id": oluwatoyinID.uuidString, "name": "Oluwatoyin", "createdAt": 2.0, "lastUsedAt": 2.0],
            ],
            "activeProfileID": lawrenceID.uuidString,
        ]
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadataURL)

        let document = try manager.loadDocument()

        XCTAssertEqual(document.version, SavedAccountsDocument.currentVersion)
        XCTAssertEqual(document.activeAccountID, oluwatoyinID)
        XCTAssertEqual(
            document.accounts.first(where: { $0.id == lawrenceID })?.accountIdentifier,
            "account-lawrence"
        )
        XCTAssertEqual(
            document.accounts.first(where: { $0.id == oluwatoyinID })?.accountIdentifier,
            "account-oluwatoyin"
        )
    }

    func testMigratesV2UsingVerifiedCurrentDisplayNameWhenIdentifiersAreMissing() throws {
        let lawrenceID = UUID()
        let oluwatoyinID = UUID()
        try credential(accountID: "account-oluwatoyin", name: "Oluwatoyin Awe")
            .write(to: authenticationURL)
        let metadata: [String: Any] = [
            "version": 2,
            "profiles": [
                ["id": lawrenceID.uuidString, "name": "Lawrence", "createdAt": 1.0, "lastUsedAt": 1.0],
                ["id": oluwatoyinID.uuidString, "name": "Oluwatoyin", "createdAt": 2.0, "lastUsedAt": 2.0],
            ],
            "activeProfileID": lawrenceID.uuidString,
        ]
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

        let document = try manager.loadDocument()

        XCTAssertEqual(document.version, SavedAccountsDocument.currentVersion)
        XCTAssertEqual(document.activeAccountID, oluwatoyinID)
        XCTAssertEqual(
            document.accounts.first(where: { $0.id == oluwatoyinID })?.accountIdentifier,
            "account-oluwatoyin"
        )
    }

    private func credential(
        accountID: String,
        name: String? = nil,
        email: String? = nil,
        accessToken: String? = nil
    ) -> Data {
        var tokens: [String: Any] = ["account_id": accountID]
        if name != nil || email != nil {
            var claims: [String: Any] = [
                "https://api.openai.com/auth": ["chatgpt_account_id": accountID]
            ]
            claims["name"] = name
            claims["email"] = email
            let payload = try! JSONSerialization.data(withJSONObject: claims)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            tokens["id_token"] = "header.\(payload).signature"
        }
        tokens["access_token"] = accessToken
        return try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
    }
}
