import XCTest

@testable import CodexDashboard

private actor ReusableDevToolsConnection: DevToolsConnectionServing {
    private var evaluationCount = 0
    private var cancellationCount = 0

    func evaluate(_ expression: String) -> DevToolsEvaluationValue {
        evaluationCount += 1
        return .boolean(true)
    }

    func cancel() {
        cancellationCount += 1
    }

    func counts() -> (evaluations: Int, cancellations: Int) {
        (evaluationCount, cancellationCount)
    }
}

private final class DevToolsConnectionFactoryProbe: @unchecked Sendable {
    let connection = ReusableDevToolsConnection()
    private let lock = NSLock()
    private var creationCount = 0

    func make(session: URLSession, url: URL) -> any DevToolsConnectionServing {
        lock.withLock { creationCount += 1 }
        return connection
    }

    func creations() -> Int {
        lock.withLock { creationCount }
    }
}

final class DevToolsClientTests: XCTestCase {
    func testTargetDecoding() throws {
        let data = Data(#"[{"id":"page-1","type":"page","title":"Codex","url":"app://codex","webSocketDebuggerUrl":"ws://127.0.0.1/devtools/page/1"}]"#.utf8)
        let targets = try JSONDecoder().decode([DevToolsTarget].self, from: data)
        XCTAssertEqual(targets.first?.id, "page-1")
        XCTAssertEqual(targets.first?.type, "page")
        XCTAssertNotNil(targets.first?.webSocketURL)
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
        let firstResult = try await client.evaluateBoolean("(() => true)()", in: target)
        let secondResult = try await client.evaluateBoolean("(() => true)()", in: target)
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
    }

    func testLiveDashboardInjectionWithoutCSPBypassWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 with a page target on port 47832.")
        }
        let client = DevToolsClient()
        let targets = await client.mainRendererTargets()
        let target = try XCTUnwrap(targets.first)
        let injection = try InjectionBundle.load()
        let mounted = try await client.evaluateBoolean(injection.mountExpression, in: target)

        XCTAssertTrue(mounted)
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

    func testEvaluationsReuseTheTargetConnection() async throws {
        let factory = DevToolsConnectionFactoryProbe()
        let client = DevToolsClient(
            session: URLSession(configuration: .ephemeral),
            connectionFactory: factory.make
        )
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )

        let firstResult = try await client.evaluateBoolean("true", in: target)
        let secondResult = try await client.evaluateBoolean("true", in: target)

        let counts = await factory.connection.counts()
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(factory.creations(), 1)
        XCTAssertEqual(counts.evaluations, 2)
        XCTAssertEqual(counts.cancellations, 0)
    }
}
