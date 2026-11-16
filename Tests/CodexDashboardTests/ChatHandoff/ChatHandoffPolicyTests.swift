import XCTest
@testable import CodexDashboard

final class ChatHandoffPolicyTests: XCTestCase {
    func testPendingActivationWaitsForTwoIdleSnapshotsAndResetsOnActivity() {
        var gate = ChatHandoffActivationGate()
        XCTAssertFalse(gate.observeIdle())
        gate.reset()
        XCTAssertFalse(gate.observeIdle())
        XCTAssertTrue(gate.observeIdle())
        gate.reset()
        XCTAssertFalse(gate.observeIdle())
    }

    func testSettingsReadsRemainAvailableButMutationsAreNotReads() {
        for method in ["configRequirements/read", "permissionProfile/list", "thread/attachment/list", "fs/readFile", "plugin/installed"] {
            XCTAssertTrue(ChatHandoffPolicy.isReadOnly(method))
        }
        for method in ["turn/start", "turn/steer", "config/batchWrite", "project/delete", "review/start"] {
            XCTAssertFalse(ChatHandoffPolicy.isReadOnly(method))
        }
    }

    func testRejectsOverlappingSendAndSwitchUntilAllChildTurnsFinish() throws {
        var policy = ChatHandoffPolicy()
        try policy.beginTurn()
        XCTAssertThrowsError(try policy.beginTurn())
        policy.observe(method: "turn/started", params: ["turn": ["id": "parent"]])
        policy.observe(method: "turn/started", params: ["turn": ["id": "child"]])
        policy.finishStarting()
        policy.observe(method: "turn/completed", params: ["turn": ["id": "parent"]])
        XCTAssertThrowsError(try policy.beginSwitch())
        XCTAssertThrowsError(try policy.beginTurn())
        policy.observe(method: "turn/completed", params: ["turn": ["id": "child"]])
        XCTAssertTrue(policy.isIdle)
        try policy.beginTurn()
    }

    func testCompletionBeforeAcknowledgmentDoesNotResurrectFinishedTurn() throws {
        var policy = ChatHandoffPolicy()
        try policy.beginTurn()
        policy.observe(method: "turn/completed", params: ["turn": ["id": "fast"]])
        policy.observe(method: "turn/started", params: ["turn": ["id": "fast"]])
        policy.finishStarting()
        XCTAssertTrue(policy.isIdle)
        try policy.beginSwitch()
        XCTAssertThrowsError(try policy.beginTurn())
        policy.finishSwitch()
        XCTAssertTrue(policy.isIdle)
    }

    func testSwitchKeepsTurnReservationUntilNewServerIsReady() throws {
        var policy = ChatHandoffPolicy()
        try policy.beginTurn()
        try policy.beginSwitch()
        XCTAssertThrowsError(try policy.beginTurn())
        policy.finishSwitch()
        XCTAssertFalse(policy.isIdle)
        policy.finishStarting()
        XCTAssertTrue(policy.isIdle)
    }
}
