import XCTest
@testable import CodexDashboard

final class AccountWindowProfileTests: XCTestCase {
    private func credential(_ id: String, token: String = "test") -> Data {
        Data("{\"tokens\":{\"account_id\":\"\(id)\",\"access_token\":\"\(token)\"}}".utf8)
    }

    func testProfilesKeepAccountsSeparateAndPreserveRefreshedCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AccountWindowProfile(accountID: UUID(), profilesDirectory: directory)
        let second = AccountWindowProfile(accountID: UUID(), profilesDirectory: directory)
        try first.prepare(credential: credential("first"), expectedAccountID: "first")
        try second.prepare(credential: credential("second"), expectedAccountID: "second")
        XCTAssertNotEqual(first.codexHome, second.codexHome)
        XCTAssertNotEqual(first.desktopData, second.desktopData)
        let auth = first.codexHome.appendingPathComponent("auth.json")
        let refreshed = credential("first", token: "refreshed")
        try refreshed.write(to: auth)
        try first.prepare(credential: credential("first", token: "stale"), expectedAccountID: "first")
        XCTAssertEqual(try Data(contentsOf: auth), refreshed)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.codexHome.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: auth.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(first.environment["CODEX_HOME"], first.codexHome.path)
        XCTAssertEqual(first.environment["CODEX_ELECTRON_USER_DATA_PATH"], first.desktopData.path)
        XCTAssertEqual(Set(first.environment.keys), ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"])
    }

    func testRejectsAnotherAccountsCredentialAndExistingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = AccountWindowProfile(accountID: UUID(), profilesDirectory: directory)
        XCTAssertThrowsError(try profile.prepare(credential: credential("wrong"), expectedAccountID: "expected"))
        try profile.prepare(credential: credential("expected"), expectedAccountID: "expected")
        try credential("wrong").write(to: profile.codexHome.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try profile.prepare(credential: nil, expectedAccountID: "expected"))
    }

    func testReopeningAfterSignOutDoesNotRestoreCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = AccountWindowProfile(accountID: UUID(), profilesDirectory: directory)
        try profile.prepare(credential: credential("account"), expectedAccountID: "account")
        let auth = profile.codexHome.appendingPathComponent("auth.json")
        try FileManager.default.removeItem(at: auth)
        try profile.prepare(credential: credential("account"), expectedAccountID: "account")
        XCTAssertFalse(FileManager.default.fileExists(atPath: auth.path))
    }

    func testRejectsSymlinkedProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = AccountWindowProfile(accountID: UUID(), profilesDirectory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profile.root, withDestinationURL: directory)
        XCTAssertThrowsError(try profile.prepare(credential: credential("account"), expectedAccountID: "account"))
    }

    func testProcessMatchingDoesNotAdoptAnotherAccountsWindow() {
        let first = AccountWindowProfile(accountID: UUID())
        let second = AccountWindowProfile(accountID: UUID())
        XCTAssertTrue(first.matches(processArguments: "ChatGPT \(first.arguments[0]) --remote-debugging-port=54321\n"))
        XCTAssertFalse(first.matches(processArguments: "ChatGPT \(second.arguments[0]) --remote-debugging-port=54321\n"))
        XCTAssertFalse(first.matches(processArguments: "ChatGPT \(first.arguments[0])-other\n"))
        XCTAssertFalse(first.matches(processArguments: "ChatGPT --remote-debugging-port=54321"))
    }

    func testMainProcessSelectionExcludesSeparateProfiles() {
        XCTAssertTrue(CodexConfiguration.isMainApplicationArguments("ChatGPT --remote-debugging-port=61234"))
        XCTAssertFalse(CodexConfiguration.isMainApplicationArguments("ChatGPT --user-data-dir=/tmp/profile"))
        XCTAssertFalse(CodexConfiguration.isMainApplicationArguments("ChatGPT --user-data-dir /tmp/profile"))
    }
}
