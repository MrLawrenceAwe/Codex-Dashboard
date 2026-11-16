import XCTest
@testable import CodexDashboard

@MainActor
final class ProjectSyncRPCWebTests: SerializedDashboardWebTestCase {
    func testProjectWritesUseTheWindowsOwnNativeConnection() async throws {
        let view = try await DashboardWebTestHarness.mountedWebView(html: "<!doctype html><html><body><aside role='navigation'><button>New chat</button></aside><main>Workspace</main></body></html>")
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const writes = [];
          let sequence = 0;
          Object.defineProperty(crypto, 'randomUUID', {value: () => `fixture-${++sequence}`});
          window.electronBridge = { sendMessageFromView(message) {
            writes.push([message.type, message.hostId, message.request.method, message.request.params.projectId]);
            window.dispatchEvent(new MessageEvent('message', {data: {
              type: 'mcp-response', hostId: 'local', message: {id: message.request.id, result: {ok: true}},
            }}));
          }};
          for (const method of ['project/create', 'project/update', 'project/move', 'project/delete']) {
            const result = JSON.parse(await window.__codexDashboard.projectRequest({method, params: {projectId: 'local-id'}}));
            if (!result.result?.ok) return [];
          }
          return writes;
        })()
        """) as? [[String]]
        XCTAssertEqual(result, ["project/create", "project/update", "project/move", "project/delete"].map {
            ["mcp-request", "local", $0, "local-id"]
        })
    }
}
