import XCTest
@testable import CodexDashboard

@MainActor
final class SharedProjectPresentationLiveTests: XCTestCase {
    func testLiveWindowsIgnoreStaleProfileFilesAndPreserveProjectRegistrations() async throws {
        guard let ports = ProcessInfo.processInfo.environment["CODEX_DASHBOARD_PRESENTATION_PORTS"]?
            .split(separator: ",").compactMap({ Int($0) }), !ports.isEmpty else {
            throw XCTSkip("Requires explicitly selected live Codex windows.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // This profile deliberately disagrees with the live native presentation.
        try Data("{}".utf8).write(to: temporary.appendingPathComponent(".codex-global-state.json"))
        let ledger = temporary.appendingPathComponent("ledger.json")
        let sync = try SharedProjectSynchronizer(file: ledger)
        var endpoints: [(id: String, home: URL, port: @Sendable () -> Int)] = []
        var connections: [ProjectSyncConnection] = []
        for (index, port) in ports.enumerated() {
            let id = index == 0 ? "main" : "shared:\(index)"
            endpoints.append((id, temporary, { port }))
            connections.append(ProjectSyncConnection(id: id, home: temporary, port: { port }))
        }
        defer { Task { for connection in connections { await connection.disconnect() }; await sync.disconnect() } }
        for connection in connections {
            let targets = await connection.client.mainRendererTargets()
            let target = try XCTUnwrap(targets.first)
            _ = try await connection.client.evaluateBoolean("""
              (() => {
                if (window.__codexDashboard?.projectRequest) return true;
                window.__codexDashboard ??= {};
                window.__codexDashboard.projectRequest = ({method, params}) => new Promise(resolve => {
                  const id = 'presentation-test-' + crypto.randomUUID();
                  const timer = setTimeout(() => finish({error: {message: 'Timed out'}}), 15000);
                  function finish(message) { clearTimeout(timer); window.removeEventListener('message', receive); resolve(JSON.stringify(message)); }
                  function receive(event) { if (event.data?.type === 'mcp-response' && event.data.message?.id === id) finish(event.data.message); }
                  window.addEventListener('message', receive);
                  window.electronBridge.sendMessageFromView({type: 'mcp-request', hostId: 'local', request: {id, method, params}});
                });
                return true;
              })()
            """, in: target)
        }
        let main = try XCTUnwrap(connections.first)
        let initial = try await main.snapshot()
        let pins = try await main.pinned(in: initial)
        XCTAssertFalse(initial.isEmpty)
        XCTAssertFalse(pins.isEmpty, "Select a fixture with native pins to exercise stale-file recovery")
        await sync.synchronizeSharedPresentation(endpoints: endpoints)
        if let error = sync.lastError { throw DashboardError.synchronizationFailed(error) }
        for connection in connections {
            let actual = try await connection.snapshot()
            let actualPins = try await connection.pinned(in: actual)
            XCTAssertEqual(Set(actual.map(\.id)), Set(initial.map(\.id)))
            XCTAssertEqual(actualPins, pins)
            let targets = await connection.client.mainRendererTargets()
            let target = try XCTUnwrap(targets.first)
            let visible = try await connection.client.evaluateBoolean(
                "[...document.querySelectorAll('[data-app-action-sidebar-project-label]')].some(e => e.checkVisibility())", in: target)
            XCTAssertTrue(visible)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path), "Shared presentation must not rewrite the replication ledger")
    }
}
