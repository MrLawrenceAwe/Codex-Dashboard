import XCTest

@testable import CodexDashboard

private actor StubRendererDevTools: DevToolsServing {
    private let rendererTargets: [DevToolsTarget]
    private var evaluationResult = false

    init(targets: [DevToolsTarget]) {
        rendererTargets = targets
    }

    func mainRendererTargets() -> [DevToolsTarget] {
        rendererTargets
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        evaluationResult
    }

    func setEvaluationResult(_ result: Bool) {
        evaluationResult = result
    }
}

@MainActor
final class DashboardRendererTests: XCTestCase {
    func testLiveRendererCompatibilityWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 with Codex on port 47832.")
        }
        let renderer = try DashboardRenderer(
            devTools: DevToolsClient(),
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertFalse(
            checks.contains { $0.status == .incompatible },
            checks.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        )
    }

    func testCompatibilityCheckExplainsUnavailableRenderer() async throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertEqual(checks.map(\.id), ["renderer"])
        XCTAssertEqual(checks.first?.status, .unavailable)
    }

    func testCompatibilityCheckInspectsRendererCapabilities() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = StubRendererDevTools(targets: [target])
        await devTools.setEvaluationResult(true)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertEqual(
            checks.map(\.id),
            [
                "renderer", "sidebar-host", "thread-navigation", "sidebar-unread",
                "composer", "prompt-menu",
            ]
        )
        XCTAssertTrue(checks.allSatisfy { $0.status == .compatible })
    }

    func testPreparingForRestartRestoresMaintenance() throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )
        renderer.stopMaintaining()
        XCTAssertFalse(renderer.maintainsDashboard)

        renderer.prepareForRestart()

        XCTAssertTrue(renderer.maintainsDashboard)
    }

    func testFailedDisableKeepsDashboardMaintenanceEnabled() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = StubRendererDevTools(targets: [target])
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        do {
            _ = try await renderer.disable()
            XCTFail("Expected the renderer to reject dashboard removal")
        } catch DashboardError.disableFailed {
            XCTAssertTrue(renderer.maintainsDashboard)
        }

        await devTools.setEvaluationResult(true)
        let disabled = try await renderer.disable()
        XCTAssertTrue(disabled)
        XCTAssertFalse(renderer.maintainsDashboard)
    }
}
