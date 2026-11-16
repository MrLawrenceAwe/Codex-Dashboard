import XCTest
@testable import CodexDashboard

@MainActor
final class SharedChatProjectLiveTests: XCTestCase {
    func testDisposableSharedBackendPreservesProjectsAndSynchronizesBothSidebars() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEX_DASHBOARD_HANDOFF_FIXTURE"] else {
            throw XCTSkip("Requires two disposable shared-chat native windows.")
        }
        struct Fixture: Decodable, Sendable { let mainHome: String; let otherHome: String; let mainPort: Int; let otherPort: Int; let ledger: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let main = ProjectSyncConnection(id: "main", home: URL(fileURLWithPath: fixture.mainHome), port: { fixture.mainPort })
        let other = ProjectSyncConnection(id: "shared:other", home: URL(fileURLWithPath: fixture.otherHome), port: { fixture.otherPort })
        defer { Task { await main.disconnect(); await other.disconnect() } }
        for connection in [main, other] {
            let targets = await connection.client.mainRendererTargets()
            let target = try XCTUnwrap(targets.first)
            let script = """
            (() => {
              window.__codexDashboard = {projectRequest: ({method, params}) => new Promise((resolve) => {
                const id = 'disposable-sync-' + crypto.randomUUID();
                const timer = setTimeout(() => finish({error: {message: 'Timed out'}}), 15000);
                function finish(message) { clearTimeout(timer); window.removeEventListener('message', receive); resolve(JSON.stringify(message)); }
                function receive(event) { if (event.data?.type === 'mcp-response' && event.data.message?.id === id) finish(event.data.message); }
                window.addEventListener('message', receive);
                window.electronBridge.sendMessageFromView({type: 'mcp-request', hostId: 'local', request: {id, method, params}});
              })};
              return true;
            })()
            """
            _ = try await connection.client.evaluateBoolean(script, in: target)
        }
        let initial = try await main.snapshot()
        XCTAssertEqual(initial.count, 1)
        var oldProject = try XCTUnwrap(initial.first)
        let originalID = oldProject.id
        oldProject = CodexProject(id: "old-other-id", name: oldProject.name, roots: oldProject.roots)
        var catalog = SharedProjectCatalog()
        catalog.observe(replicaID: "main", snapshot: initial)
        catalog.observe(replicaID: "other", snapshot: [oldProject])
        let ledger = URL(fileURLWithPath: fixture.ledger)
        try JSONEncoder().encode(catalog).write(to: ledger)
        let sync = try SharedProjectSynchronizer(file: ledger)
        let endpoints: [(id: String, home: URL, port: @Sendable () -> Int)] = [
            ("main", main.home, { fixture.mainPort }), ("shared:other", other.home, { fixture.otherPort })
        ]
        func synchronize() async throws {
            await sync.synchronize(endpoints: endpoints)
            if let error = sync.lastError { throw DashboardError.synchronizationFailed(error) }
        }
        try await synchronize()
        let retained = try await main.snapshot()
        XCTAssertEqual(retained.map(\.id), [originalID], "Changing backend must not delete the original project")
        let folder = main.home.deletingLastPathComponent().appendingPathComponent("project-test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await other.request("project/create", ["idempotencyKey": UUID().uuidString, "name": "Shared backend project test", "roots": [["path": folder.path]]])
        try await synchronize()
        let projects = try await main.snapshot()
        let added = try XCTUnwrap(projects.first { $0.id != originalID })
        let stored = try JSONDecoder().decode(SharedProjectCatalog.self, from: Data(contentsOf: ledger))
        XCTAssertEqual(stored.projects.count, 2, "One backend project must not become two shared identities")
        try await other.setPresentation(order: [added.id, originalID], pinned: [added.id], snapshot: projects)
        try await synchronize()
        let pinnedSnapshot = try await main.snapshot()
        let pins = try await main.pinned(in: pinnedSnapshot)
        XCTAssertTrue(pins.contains(added.id))
        _ = try await other.request("project/update", ["projectId": added.id, "name": "Renamed through other window"])
        try await synchronize()
        for connection in [main, other] {
            let targets = await connection.client.mainRendererTargets()
            let target = try XCTUnwrap(targets.first)
            var visible = false
            for _ in 0..<30 {
                visible = try await connection.client.evaluateBoolean("document.body.innerText.includes('Renamed through other window')", in: target)
                if visible { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(visible)
        }
        _ = try await main.request("project/delete", ["projectId": added.id])
        try await synchronize()
        let remaining = try await other.snapshot()
        XCTAssertEqual(remaining.map(\.id), [originalID])
        await sync.disconnect()
    }
}
