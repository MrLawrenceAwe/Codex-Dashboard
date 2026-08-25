import Foundation
import XCTest

@testable import CodexDashboard

private final class MemoryAccountCredentialVault: AccountCredentialVault, @unchecked Sendable {
    enum TestError: Error { case deletionFailed }

    private var values: [UUID: Data] = [:]
    private var deletionCount = 0
    private var deletionShouldFail = false
    private let lock = NSLock()

    func credential(for accountID: UUID) -> Data? {
        lock.withLock { values[accountID] }
    }

    func store(_ credential: Data, for accountID: UUID) {
        lock.withLock { values[accountID] = credential }
    }

    func deleteCredential(for accountID: UUID) throws {
        try lock.withLock {
            if deletionShouldFail { throw TestError.deletionFailed }
            deletionCount += 1
            values.removeValue(forKey: accountID)
        }
    }

    var deleteCallCount: Int { lock.withLock { deletionCount } }

    func failDeletion() {
        lock.withLock { deletionShouldFail = true }
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
        let credential = Data(#"{"tokens":{"access_token":"secret"}}"#.utf8)
        try credential.write(to: authenticationURL)

        let account = try manager.saveCurrentAccount(named: " Personal ")
        let document = try manager.document()

        XCTAssertEqual(account.name, "Personal")
        XCTAssertEqual(document.accounts, [account])
        XCTAssertEqual(document.activeAccountID, account.id)
        XCTAssertEqual(vault.credential(for: account.id), credential)
        XCTAssertFalse(String(data: try Data(contentsOf: metadataURL), encoding: .utf8)!.contains("secret"))
    }

    func testSwitchSavesRotatedActiveCredentialAndRollbackRestoresIt() throws {
        let personal = Data(#"{"account":"personal-original"}"#.utf8)
        try personal.write(to: authenticationURL)
        let personalAccount = try manager.saveCurrentAccount(named: "Personal")

        _ = try manager.beginAddingAccount()
        let work = Data(#"{"account":"work"}"#.utf8)
        try work.write(to: authenticationURL)
        let workAccount = try manager.saveCurrentAccount(named: "Work")

        let rotatedWork = Data(#"{"account":"work-rotated"}"#.utf8)
        try rotatedWork.write(to: authenticationURL)
        let transaction = try manager.activate(accountID: personalAccount.id)

        XCTAssertEqual(try Data(contentsOf: authenticationURL), personal)
        XCTAssertEqual(vault.credential(for: workAccount.id), rotatedWork)
        XCTAssertEqual(try manager.document().activeAccountID, personalAccount.id)

        try manager.rollback(transaction)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), rotatedWork)
        XCTAssertEqual(try manager.document().activeAccountID, workAccount.id)
    }

    func testBeginAddingAccountSignsOutAndCanRollback() throws {
        let credential = Data(#"{"account":"current"}"#.utf8)
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount(named: "Current")

        let transaction = try manager.beginAddingAccount()
        XCTAssertFalse(FileManager.default.fileExists(atPath: authenticationURL.path))
        XCTAssertNil(try manager.document().activeAccountID)

        try manager.rollback(transaction)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), credential)
        XCTAssertEqual(try manager.document().activeAccountID, account.id)
    }

    func testUnsupportedMetadataVersionIsNotOverwritten() throws {
        let unsupportedDocument = Data(
            #"{"version":99,"profiles":[],"activeProfileID":null}"#.utf8
        )
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try unsupportedDocument.write(to: metadataURL)
        try Data(#"{"account":"current"}"#.utf8).write(to: authenticationURL)

        XCTAssertThrowsError(try manager.beginAddingAccount()) { error in
            guard case CodexAccountError.unsupportedMetadataVersion(99) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), unsupportedDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: authenticationURL.path))
    }

    func testDeleteDoesNotRemoveCredentialWhenMetadataCannotBeSaved() throws {
        let credential = Data(#"{"account":"personal"}"#.utf8)
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount(named: "Personal")
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
        let credential = Data(#"{"account":"personal"}"#.utf8)
        try credential.write(to: authenticationURL)
        let account = try manager.saveCurrentAccount(named: "Personal")
        vault.failDeletion()

        XCTAssertThrowsError(try manager.deleteAccount(account.id)) { error in
            XCTAssertTrue(error is MemoryAccountCredentialVault.TestError)
        }
        XCTAssertEqual(try manager.document().accounts, [account])
        XCTAssertEqual(vault.credential(for: account.id), credential)
    }

    func testReconcilesStaleActiveAccountWithCurrentCodexAccount() throws {
        let lawrenceCredential = credential(accountID: "account-lawrence")
        try lawrenceCredential.write(to: authenticationURL)
        let lawrence = try manager.saveCurrentAccount(named: "Lawrence")

        _ = try manager.beginAddingAccount()
        let oluwatoyinCredential = credential(accountID: "account-oluwatoyin")
        try oluwatoyinCredential.write(to: authenticationURL)
        let oluwatoyin = try manager.saveCurrentAccount(named: "Oluwatoyin")

        var metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadataURL)
        ) as! [String: Any]
        metadata["activeProfileID"] = lawrence.id.uuidString
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

        let document = try manager.document()

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

    func testMigratesExistingAccountsAndReconcilesTheirAccountIdentifiers() throws {
        let lawrenceID = UUID()
        let oluwatoyinID = UUID()
        vault.store(credential(accountID: "account-lawrence"), for: lawrenceID)
        vault.store(credential(accountID: "account-oluwatoyin"), for: oluwatoyinID)
        try credential(accountID: "account-oluwatoyin").write(to: authenticationURL)
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

        let document = try manager.document()

        XCTAssertEqual(document.version, 3)
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

        let document = try manager.document()

        XCTAssertEqual(document.version, 3)
        XCTAssertEqual(document.activeAccountID, oluwatoyinID)
        XCTAssertEqual(
            document.accounts.first(where: { $0.id == oluwatoyinID })?.accountIdentifier,
            "account-oluwatoyin"
        )
    }

    private func credential(accountID: String, name: String? = nil) -> Data {
        var tokens: [String: Any] = ["account_id": accountID]
        if let name {
            let claims: [String: Any] = [
                "name": name,
                "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
            ]
            let payload = try! JSONSerialization.data(withJSONObject: claims)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            tokens["id_token"] = "header.\(payload).signature"
        }
        return try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
    }
}
