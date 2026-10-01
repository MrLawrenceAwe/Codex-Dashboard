import XCTest

@testable import CodexDashboard

private actor SpeechInputDevTools: DevToolsServing {
    let activeTargetID: String?
    let failingTargetID: String?

    init(activeTargetID: String? = nil, failingTargetID: String? = nil) {
        self.activeTargetID = activeTargetID
        self.failingTargetID = failingTargetID
    }

    func mainRendererTargets() -> [DevToolsTarget] {
        ["first", "second"].map {
            DevToolsTarget(id: $0, type: "page", url: "app://-/index.html", webSocketURL: "ws://127.0.0.1/\($0)")
        }
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) throws -> Bool {
        if target.id == failingTargetID { throw URLError(.cannotConnectToHost) }
        return target.id == activeTargetID
    }

    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { nil }
}

@MainActor
final class SpeechInputRendererTests: XCTestCase {
    func testSpeechInAnotherWindowSuppressesFocus() async throws {
        let renderer = try DashboardRenderer(devTools: SpeechInputDevTools(activeTargetID: "second"))
        let active = await renderer.hasActiveSpeechInput()
        XCTAssertTrue(active)
    }

    func testInactiveWindowsAllowFocus() async throws {
        let renderer = try DashboardRenderer(devTools: SpeechInputDevTools())
        let active = await renderer.hasActiveSpeechInput()
        XCTAssertFalse(active)
    }

    func testUninspectableWindowSuppressesFocus() async throws {
        let renderer = try DashboardRenderer(devTools: SpeechInputDevTools(failingTargetID: "first"))
        let active = await renderer.hasActiveSpeechInput()
        XCTAssertTrue(active)
    }
}
