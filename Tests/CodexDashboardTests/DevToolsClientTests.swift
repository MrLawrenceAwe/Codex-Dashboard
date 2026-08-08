import XCTest

@testable import CodexDashboard

final class DevToolsClientTests: XCTestCase {
    func testPackagedDashboardResourcesLoad() throws {
        let adapter = try DashboardAdapter.load()
        XCTAssertTrue(adapter.expression.contains("window.__codexDashboard"))
        XCTAssertTrue(adapter.expression.contains("#codex-dashboard-page"))
        XCTAssertTrue(adapter.healthCheckExpression.contains(adapter.version))
    }

    func testPreviewUsesDashboardPayloadContract() throws {
        let previewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DashboardPreview/preview.js")
        let preview = try String(contentsOf: previewURL, encoding: .utf8)
        XCTAssertTrue(preview.contains("update({ threads, totalThreadCount:"))
        XCTAssertFalse(preview.contains("update(["))
    }

    func testTargetDecoding() throws {
        let data = Data(#"[{"id":"page-1","type":"page","title":"Codex","url":"app://codex","webSocketDebuggerUrl":"ws://127.0.0.1/devtools/page/1"}]"#.utf8)
        let targets = try JSONDecoder().decode([DevToolsTarget].self, from: data)
        XCTAssertEqual(targets.first?.id, "page-1")
        XCTAssertEqual(targets.first?.type, "page")
        XCTAssertNotNil(targets.first?.webSocketDebuggerUrl)
    }

    func testOnlyMainRendererIsEligible() throws {
        let data = Data(#"""
        [
          {"id":"main","type":"page","title":"Codex","url":"app://-/index.html","webSocketDebuggerUrl":"ws://127.0.0.1/main"},
          {"id":"hotkey","type":"page","title":"Codex","url":"app://-/index.html?initialRoute=%2Fhotkey-window","webSocketDebuggerUrl":"ws://127.0.0.1/hotkey"},
          {"id":"avatar","type":"page","title":"Codex","url":"app://-/index.html?initialRoute=%2Favatar-overlay","webSocketDebuggerUrl":"ws://127.0.0.1/avatar"}
        ]
        """#.utf8)
        let targets = try JSONDecoder().decode([DevToolsTarget].self, from: data)
            .filter(DevToolsClient.isMainRenderer)
        XCTAssertEqual(targets.map(\.id), ["main"])
    }

    func testLiveRoundTripWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 with a page target on port 47832.")
        }
        let client = DevToolsClient()
        let deadline = ContinuousClock.now + .seconds(8)
        var targets: [DevToolsTarget] = []
        while targets.isEmpty, ContinuousClock.now < deadline {
            targets = await client.mainRendererTargets()
            if targets.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
        }
        let target = try XCTUnwrap(targets.first)
        let result = try await client.evaluateBoolean("(() => true)()", in: target)
        XCTAssertTrue(result)
    }

    func testTimeoutCancelsSlowOperation() async throws {
        do {
            _ = try await withDevToolsTimeout(.milliseconds(10)) {
                try await Task.sleep(for: .seconds(5))
                return true
            }
            XCTFail("Expected the operation to time out")
        } catch DashboardError.devToolsTimedOut {
            // Expected.
        }
    }
}
