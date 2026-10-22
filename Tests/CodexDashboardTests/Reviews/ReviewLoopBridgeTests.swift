import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopBridgeTests: ReviewLoopTestCase {
    func testSlowInspectionDoesNotBlockSnapshotsOrStopReceiptAndStillDrains() async throws {
        let (_, store, driver) = try make()
        let loopID = try XCTUnwrap(store.loops.first?.id)
        let devTools = ReviewBridgeDevTools()
        let bridge = ReviewLoopBridge(devTools: devTools, store: store, makeDriver: { _ in driver })
        let inspecting = expectation(description: "Inspection started")
        var release: CheckedContinuation<Void, Never>?
        driver.onWorkspaceAsync = {
            await withCheckedContinuation { continuation in
                release = continuation
                inspecting.fulfill()
            }
        }
        try await devTools.queue(ReviewLoopAction(id: "resume", kind: .resume, projectID: nil, promptContext: nil, maxRounds: nil, loopID: loopID))
        try await bridge.synchronize(targets: [target], threads: [])
        await fulfillment(of: [inspecting], timeout: 2)
        try await devTools.queue(ReviewLoopAction(id: "stop", kind: .stop, projectID: nil, promptContext: nil, maxRounds: nil, loopID: loopID))
        try await bridge.synchronize(targets: [target], threads: [])
        XCTAssertEqual(store.loops.first?.phase, .stopped)
        let deliveries = await devTools.deliveryCount
        XCTAssertGreaterThanOrEqual(deliveries, 2)
        var drained = false
        let drain = Task { await bridge.waitForOperations(); drained = true }
        await Task.yield()
        XCTAssertFalse(drained)
        release?.resume()
        await drain.value
        XCTAssertTrue(drained)
        XCTAssertEqual(driver.createCalls, 0, "Stop during inspection must prevent a late chat launch")
    }

    func testSlowChoicesDoNotBlockSnapshotsOrDuplicateChoiceRequests() async throws {
        let store = ReviewTestStore()
        let driver = ReviewTestDriver()
        let devTools = ReviewBridgeDevTools()
        let bridge = ReviewLoopBridge(devTools: devTools, store: store, makeDriver: { _ in driver })
        let loading = expectation(description: "Choices started")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        driver.onProjectsAsync = {
            calls += 1
            await withCheckedContinuation { continuation in
                release = continuation
                loading.fulfill()
            }
        }
        try await bridge.synchronize(targets: [target], threads: [])
        await fulfillment(of: [loading], timeout: 2)
        try await bridge.synchronize(targets: [target], threads: [])
        XCTAssertEqual(calls, 1)
        let deliveries = await devTools.deliveryCount
        XCTAssertEqual(deliveries, 2)
        release?.resume()
        await bridge.waitForOperations()
    }

    private var target: DevToolsTarget {
        DevToolsTarget(id: "review", type: "page", url: nil, webSocketURL: nil)
    }

    func testUnknownReviewActionKindDoesNotDecode() {
        let payload = Data(#"{"id":"unknown","kind":"retry"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ReviewLoopAction.self, from: payload))
    }

    func testReviewFileLinksStayInsideTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-files-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("File.swift")
        try Data("source".utf8).write(to: file)
        let outside = root.appendingPathComponent("outside.swift")
        try Data("outside".utf8).write(to: outside)
        let alias = project.appendingPathComponent("alias.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        XCTAssertEqual(ReviewLoopBridge.reviewFileURL("File.swift:12", projectPath: project.path), file)
        XCTAssertEqual(ReviewLoopBridge.reviewFileURL(file.absoluteString, projectPath: project.path), file)
        XCTAssertNil(ReviewLoopBridge.reviewFileURL("../outside.swift", projectPath: project.path))
        XCTAssertNil(ReviewLoopBridge.reviewFileURL(outside.path, projectPath: project.path))
        XCTAssertNil(ReviewLoopBridge.reviewFileURL("alias.swift", projectPath: project.path))
    }
}

private actor ReviewBridgeDevTools: DevToolsServing {
    private var action: String?
    private(set) var deliveryCount = 0
    func queue(_ action: ReviewLoopAction) throws {
        self.action = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
    }
    func mainRendererTargets() -> [DevToolsTarget] { [] }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        if expression.contains("applyReviewPageSnapshot") { deliveryCount += 1 }
        return true
    }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? {
        defer { action = nil }
        return action
    }
}
