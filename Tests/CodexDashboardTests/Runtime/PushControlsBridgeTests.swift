import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
final class PushControlsBridgeTests: XCTestCase {
    func testLocalRemoteDetectionDistinguishesNoRemoteRemoteAndUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unavailable = await PushControlsBridge.hasRemote(at: directory.path)
        XCTAssertNil(unavailable)
        _ = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "init", "--quiet"], timeout: 3)
        let absent = await PushControlsBridge.hasRemote(at: directory.path)
        XCTAssertEqual(absent, false)
        // An unreachable URL is sufficient: inspecting remotes never uses the network.
        _ = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "remote", "add", "origin", "https://invalid.example/repository.git"], timeout: 3)
        let present = await PushControlsBridge.hasRemote(at: directory.path)
        XCTAssertEqual(present, true)
        _ = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "remote", "remove", "origin"], timeout: 3)
        let removed = await PushControlsBridge.hasRemote(at: directory.path)
        XCTAssertEqual(removed, false)
    }
}

private actor PushInspectionDevTools: DevToolsServing {
    let value: String
    init(_ value: String) { self.value = value }
    func mainRendererTargets() -> [DevToolsTarget] { [] }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { value }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool { true }
}

@MainActor
extension PushControlsBridgeTests {
    func testChangedMenuProducesNonBlockingCompatibilityWarning() async throws {
        let target = DevToolsTarget(id: "main", type: "page", url: nil, webSocketURL: nil)
        let bridge = PushControlsBridge(devTools: PushInspectionDevTools(
            #"{"state":"incompatible","requestID":1,"path":null}"#
        ))
        let result = await bridge.synchronize(in: [target])
        let check = try XCTUnwrap(result)
        XCTAssertEqual(check.id, "disable-push-without-remote")
        XCTAssertEqual(check.title, "Disable push without a remote")
        XCTAssertEqual(check.status, .warning)
        XCTAssertTrue(check.detail.contains("Push controls changed in Codex"))
        XCTAssertEqual(CompatibilityReport(checks: [check]).blockingCount, 0)
    }
}
