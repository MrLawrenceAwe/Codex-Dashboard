import Foundation
import XCTest

@testable import CodexDashboard

private final class MemoryAccountCredentialVault: AccountCredentialVault, @unchecked Sendable {
    private var values: [UUID: Data] = [:]
    private let lock = NSLock()

    func credential(for profileID: UUID) -> Data? {
        lock.withLock { values[profileID] }
    }

    func store(_ credential: Data, for profileID: UUID) {
        lock.withLock { values[profileID] = credential }
    }

    func deleteCredential(for profileID: UUID) {
        _ = lock.withLock { values.removeValue(forKey: profileID) }
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

        let profile = try manager.saveCurrentAccount(named: " Personal ")
        let document = try manager.document()

        XCTAssertEqual(profile.name, "Personal")
        XCTAssertEqual(document.profiles, [profile])
        XCTAssertEqual(document.activeProfileID, profile.id)
        XCTAssertEqual(vault.credential(for: profile.id), credential)
        XCTAssertFalse(String(data: try Data(contentsOf: metadataURL), encoding: .utf8)!.contains("secret"))
    }

    func testSwitchSavesRotatedActiveCredentialAndRollbackRestoresIt() throws {
        let personal = Data(#"{"account":"personal-original"}"#.utf8)
        try personal.write(to: authenticationURL)
        let personalProfile = try manager.saveCurrentAccount(named: "Personal")

        _ = try manager.beginAddingAccount()
        let work = Data(#"{"account":"work"}"#.utf8)
        try work.write(to: authenticationURL)
        let workProfile = try manager.saveCurrentAccount(named: "Work")

        let rotatedWork = Data(#"{"account":"work-rotated"}"#.utf8)
        try rotatedWork.write(to: authenticationURL)
        let transaction = try manager.activate(profileID: personalProfile.id)

        XCTAssertEqual(try Data(contentsOf: authenticationURL), personal)
        XCTAssertEqual(vault.credential(for: workProfile.id), rotatedWork)
        XCTAssertEqual(try manager.document().activeProfileID, personalProfile.id)

        try manager.rollback(transaction)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), rotatedWork)
        XCTAssertEqual(try manager.document().activeProfileID, workProfile.id)
    }

    func testBeginAddingAccountSignsOutAndCanRollback() throws {
        let credential = Data(#"{"account":"current"}"#.utf8)
        try credential.write(to: authenticationURL)
        let profile = try manager.saveCurrentAccount(named: "Current")

        let transaction = try manager.beginAddingAccount()
        XCTAssertFalse(FileManager.default.fileExists(atPath: authenticationURL.path))
        XCTAssertNil(try manager.document().activeProfileID)

        try manager.rollback(transaction)
        XCTAssertEqual(try Data(contentsOf: authenticationURL), credential)
        XCTAssertEqual(try manager.document().activeProfileID, profile.id)
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
}
