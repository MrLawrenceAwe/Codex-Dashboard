import XCTest
@testable import CodexDashboard

final class LegacySharedChatRecoveryTests: XCTestCase {
    private let address = "ws://dashboard:test-only@127.0.0.1:50000"

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("shared-chat")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("owner"), withIntermediateDirectories: true)
        let endpoint = ChatHandoffServer.Endpoint(id: "main", url: address, supportsAccountSwitch: true)
        try JSONEncoder().encode([endpoint]).write(to: root.appendingPathComponent("ready.json"))
        for name in ["enabled", "activate-when-idle", "previous-force-cli", "previous-ws-url"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try Data("32101".utf8).write(to: root.appendingPathComponent("owner-pid"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("configuration.json"))
        try Data("ledger-sentinel".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("shared-projects.json"))
        try Data("credential-sentinel".utf8).write(to: root.appendingPathComponent("owner/auth.json"))
        return root
    }

    func testRetiresOwnedRoutingAndArchivesMetadataWithoutChangingCredentials() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var environment = ["CODEX_APP_SERVER_WS_URL": address, "CODEX_APP_SERVER_FORCE_CLI": "0"]
        let recovery = LegacySharedChatRecovery(root: root,
            readEnvironment: { environment[$0] ?? "" }, unsetEnvironment: { environment.removeValue(forKey: $0) },
            processIsAlive: { _ in false })
        let archive = try XCTUnwrap(recovery.recover())
        XCTAssertTrue(environment.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("enabled").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("configuration.json").path))
        XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("shared-projects.json"), encoding: .utf8), "ledger-sentinel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("shared-projects.json").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("owner/auth.json"), encoding: .utf8), "credential-sentinel")
        XCTAssertNil(try recovery.recover())
    }

    func testPreservesAnUnrelatedAppServerConfiguration() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let environment = ["CODEX_APP_SERVER_WS_URL": "ws://unrelated.example.test", "CODEX_APP_SERVER_FORCE_CLI": "0"]
        var removed: [String] = []
        try LegacySharedChatRecovery(root: root,
            readEnvironment: { environment[$0] ?? "" }, unsetEnvironment: { removed.append($0) },
            processIsAlive: { _ in false }).recover()
        XCTAssertTrue(removed.isEmpty)
    }

    func testAnActiveWriterPreventsRetirementAndNativeFallback() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var removed: [String] = []
        XCTAssertThrowsError(try LegacySharedChatRecovery(root: root,
            readEnvironment: { _ in self.address }, unsetEnvironment: { removed.append($0) },
            processIsAlive: { _ in true }, processArguments: { _ in "/bundle/codex app-server --stdio" }).recover())
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("enabled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("recovery").path))
    }

    func testPartialEnvironmentCleanupCanBeRetried() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var environment = ["CODEX_APP_SERVER_WS_URL": address, "CODEX_APP_SERVER_FORCE_CLI": "0"]
        var fail = true
        let recovery = LegacySharedChatRecovery(root: root,
            readEnvironment: { environment[$0] ?? "" }, unsetEnvironment: {
                if $0 == "CODEX_APP_SERVER_FORCE_CLI", fail { throw CocoaError(.fileWriteUnknown) }
                environment.removeValue(forKey: $0)
            }, processIsAlive: { _ in false })
        XCTAssertThrowsError(try recovery.recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("enabled").path))
        fail = false
        try recovery.recover()
        XCTAssertTrue(environment.isEmpty)
    }
}
