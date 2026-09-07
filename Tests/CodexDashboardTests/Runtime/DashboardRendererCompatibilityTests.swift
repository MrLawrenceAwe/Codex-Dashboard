import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension DashboardRendererTests {
    func testLiveRendererCompatibilityWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip(
                "Set CODEX_DASHBOARD_LIVE_TEST=1 with Codex on port \(CodexConfiguration.devToolsPort)."
            )
        }
        let renderer = try DashboardRenderer(
            devTools: DevToolsClient(),
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertTrue(
            checks.allSatisfy { $0.status == .compatible },
            checks.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        )
    }

    func testCompatibilityCheckExplainsUnavailableRenderer() async throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
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
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertEqual(
            checks.map(\.id),
            [
                "renderer", "sidebar-host", "thread-navigation", "sidebar-unread",
                "composer", "composer-controls", "model-picker",
            ]
        )
        XCTAssertTrue(checks.allSatisfy { $0.status == .compatible })
        let expressions = await devTools.expressions()
        let composerControlsExpression = try XCTUnwrap(
            expressions.first { $0.contains("Boolean(codexUIContracts.composerAddButton())") }
        )
        XCTAssertFalse(composerControlsExpression.contains("data-codex-prompt-launcher"))
        XCTAssertTrue(
            expressions.contains { $0.contains("codexUIContracts.probeModelPickerControls()") }
        )
    }

}
