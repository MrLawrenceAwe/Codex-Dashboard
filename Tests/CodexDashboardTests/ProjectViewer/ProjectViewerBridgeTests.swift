import XCTest

@testable import CodexDashboard

@MainActor
final class ProjectViewerBridgeTests: XCTestCase {
    func testSidebarRootMustBelongToSavedProjectEvenWithoutChats() async throws {
        let database = try CodexTestFixtures.makeDatabase(schema: """
            CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE project_roots (project_id TEXT NOT NULL, path TEXT NOT NULL);
            INSERT INTO projects VALUES ('saved', 'Saved'), ('other', 'Other');
            INSERT INTO project_roots VALUES ('saved', '/tmp/saved project'), ('other', '/tmp/other');
            """, testCase: self)
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let host = "local:" + database.deletingLastPathComponent().path
        let aliases = ["app-server-project-id-by-legacy-project-id-by-host": [host: ["visible-id": "saved"]]]
        try JSONEncoder().encode(aliases).write(to: state)
        let bridge = ProjectViewerBridge(catalog: CodexThreadCatalogProvider(stateDatabaseURL: database, globalStateURL: state))
        let root = await bridge.allowedRoot(.init(id: "1", path: "/tmp/saved project", projectID: "visible-id"), threads: [])
        let wrongProject = await bridge.allowedRoot(.init(id: "2", path: "/tmp/saved project", projectID: "other"), threads: [])
        let wrongPath = await bridge.allowedRoot(.init(id: "3", path: "/tmp/other", projectID: "saved"), threads: [])
        XCTAssertEqual(root, FileSystemPath.canonicalURL("/tmp/saved project"))
        XCTAssertNil(wrongProject)
        XCTAssertNil(wrongPath)
    }
}
