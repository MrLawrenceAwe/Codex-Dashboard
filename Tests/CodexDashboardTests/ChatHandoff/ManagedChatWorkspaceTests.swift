import XCTest
@testable import CodexDashboard

@MainActor
final class ManagedChatWorkspaceTests: XCTestCase {
    func testManagedProfilesNeverReuseNormalOrIndependentStorage() throws {
        let id = UUID()
        let managed = ManagedChatWorkspace()
        let profile = managed.profile(id)
        XCTAssertNotEqual(profile.codexHome, AccountWindowProfile(accountID: id).codexHome)
        XCTAssertNotEqual(managed.history, CodexConfiguration.codexDirectory)
        XCTAssertTrue(FileSystemPath.contains(profile.root.path, in: managed.windows.path))
        XCTAssertThrowsError(try ManagedChatWorkspace(root: URL(fileURLWithPath: "/tmp/absent-" + UUID().uuidString)).environment(id))
    }

    func testHeadlessReadinessAndScopedEnvironmentUseOnlyPrivateStorage() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = ManagedChatWorkspace(root: temporary)
        let id = UUID()
        let profile = workspace.profile(id)
        try profile.prepare(credential: testAccountCredential(accountID: "managed-test", name: "Managed"), expectedAccountID: "managed-test")
        try FileManager.default.createDirectory(at: workspace.history, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.server, withIntermediateDirectories: true)
        let fake = temporary.appendingPathComponent("fake-codex")
        try #"""
#!/usr/bin/env python3
import json,sys
for line in sys.stdin:
    request=json.loads(line)
    if 'id' in request: print(json.dumps({'id':request['id'],'result':{}}),flush=True)
"""#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let configuration = ChatHandoffServer.Configuration(root: workspace.server, historyHome: workspace.history, executable: fake,
            windows: [.init(id: id.uuidString.lowercased(), home: profile.codexHome, accountIdentifier: "managed-test", token: UUID().uuidString)])
        try JSONEncoder().encode(configuration).write(to: workspace.configuration)
        let product = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CodexDashboard")
        let process = Process()
        process.executableURL = product
        process.arguments = ["--shared-chat-server", workspace.configuration.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: temporary)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: workspace.server.appendingPathComponent("ready.json").path) { break }
            guard process.isRunning else { return XCTFail("Managed server could not initialize") }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(workspace.brokerPID, process.processIdentifier)
        let environment = try workspace.environment(id)
        XCTAssertEqual(environment["CODEX_HOME"], profile.codexHome.path)
        XCTAssertNotNil(environment["CODEX_APP_SERVER_WS_URL"])
        XCTAssertNil(AccountWindowProfile(accountID: id).environment["CODEX_APP_SERVER_WS_URL"])
        let endpoint = try XCTUnwrap(workspace.endpoints(ready: false).first)
        let response = try await ManagedChatRPC(endpoint: endpoint).request("dashboard/status")
        let result = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        XCTAssertEqual((result?["result"] as? [String: Any])?["healthy"] as? Bool, true)
    }
}
