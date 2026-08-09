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
    func testPreparingForRestartRestoresMaintenance() throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injection: DashboardInjection(version: "test", mountExpression: "true")
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
            injection: DashboardInjection(version: "test", mountExpression: "true")
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
