import XCTest
@testable import CodexDashboard

final class ProjectSyncProtocolTests: XCTestCase {
    func testNativeProjectRemovalKeepsItsChatsAndDoesNotChangeSignIn() async throws {
        guard FileManager.default.isExecutableFile(atPath: CodexConfiguration.codexExecutableURL.path) else {
            throw XCTSkip("Requires the installed Codex app-server for local project API validation.")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectSyncProtocol-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = try CodexAppServerSession(executableURL: CodexConfiguration.codexExecutableURL, codexHomeURL: home)
        defer { session.terminate() }
        _ = try await session.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "codex-dashboard-test", "version": "1"], "capabilities": ["experimentalApi": true]
        ], timeout: .seconds(12))
        try session.notify(method: "initialized")
        let created = try await session.request(id: 2, method: "project/create", params: [
            "idempotencyKey": UUID().uuidString, "name": "Test project", "roots": [["path": home.path]]
        ], timeout: .seconds(12))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: created) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let project = try XCTUnwrap(result["project"] as? [String: Any])
        let projectID = try XCTUnwrap(project["id"] as? String)
        // Empty thread/start sessions are not persisted until they have a turn.
        // Seed a durable chat in this disposable fixture without sending a turn.
        let safeID = projectID.replacingOccurrences(of: "'", with: "''")
        let fixture = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"), arguments: [
            home.appendingPathComponent("state_5.sqlite").path,
            "INSERT INTO threads (id,rollout_path,created_at,updated_at,source,model_provider,cwd,title,sandbox_policy,approval_mode,project_id) VALUES ('\(UUID().uuidString)', '', 1, 1, 'cli', 'openai', '/tmp', 'Keep this chat', '{}', 'never', '\(safeID)');"
        ], timeout: 5)
        XCTAssertEqual(fixture.terminationStatus, 0)
        _ = try await session.request(id: 4, method: "project/delete", params: ["projectId": projectID], timeout: .seconds(12))
        let counts = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"), arguments: [
            "-readonly", "-json", home.appendingPathComponent("state_5.sqlite").path,
            "SELECT (SELECT count(*) FROM projects) AS projects, (SELECT count(*) FROM threads) AS chats;"
        ], timeout: 5)
        let row = try XCTUnwrap((try JSONSerialization.jsonObject(with: counts.standardOutput) as? [[String: Any]])?.first)
        XCTAssertEqual(row["projects"] as? Int, 0)
        XCTAssertEqual(row["chats"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }
}
