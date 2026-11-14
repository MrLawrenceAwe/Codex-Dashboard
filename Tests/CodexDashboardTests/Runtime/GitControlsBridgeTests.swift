import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
final class GitControlsBridgeTests: XCTestCase {}

private actor PushInspectionDevTools: DevToolsServing {
    let value: String
    init(_ value: String) { self.value = value }
    func mainRendererTargets() -> [DevToolsTarget] { [] }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { value }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool { true }
}

@MainActor
extension GitControlsBridgeTests {
    func testChangedMenuProducesNonBlockingCompatibilityWarning() async throws {
        let target = DevToolsTarget(id: "main", type: "page", url: nil, webSocketURL: nil)
        let bridge = GitControlsBridge(devTools: PushInspectionDevTools(
            #"{"pushControls":{"state":"incompatible"}}"#
        ))
        let result = await bridge.synchronize(in: [target])
        let check = try XCTUnwrap(result.first { $0.id == GitControlsBridge.pushControlsID })
        XCTAssertEqual(check.id, "disable-push-without-remote")
        XCTAssertEqual(check.title, "Disable push without a remote")
        XCTAssertEqual(check.status, .warning)
        XCTAssertTrue(check.detail.contains("Push controls changed in Codex"))
        XCTAssertEqual(CompatibilityReport(checks: [check]).blockingCount, 0)
    }
}

@MainActor
extension GitControlsBridgeTests {
    func testUnavailableGitChannelProducesNonBlockingWarning() async throws {
        let target = DevToolsTarget(id: "main", type: "page", url: nil, webSocketURL: nil)
        let bridge = GitControlsBridge(devTools: PushInspectionDevTools(#"{"pushControls":{"state":"remote-unavailable"}}"#))
        let result = await bridge.synchronize(in: [target])
        let check = try XCTUnwrap(result.first { $0.id == GitControlsBridge.pushControlsID })
        XCTAssertEqual(check.status, .warning)
        XCTAssertTrue(check.detail.contains("Git remotes could not be checked through Codex"))
        XCTAssertEqual(CompatibilityReport(checks: [check]).blockingCount, 0)
    }
}

@MainActor
extension GitControlsBridgeTests {
    func testUnopenedDialogIsPendingWithoutWarning() async throws {
        let target = DevToolsTarget(id: "main", type: "page", url: nil, webSocketURL: nil)
        let bridge = GitControlsBridge(devTools: PushInspectionDevTools(#"{"pushControls":{"state":"waiting"}}"#))
        let result = await bridge.synchronize(in: [target])
        let check = try XCTUnwrap(result.first { $0.id == GitControlsBridge.pushControlsID })
        XCTAssertEqual(check.status, .pending)
        XCTAssertTrue(CompatibilityReport(checks: [check]).attentionChecks.isEmpty)
    }
}
