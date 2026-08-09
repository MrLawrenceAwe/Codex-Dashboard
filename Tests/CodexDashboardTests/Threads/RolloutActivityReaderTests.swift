import XCTest

@testable import CodexDashboard

final class RolloutActivityReaderTests: XCTestCase {
    func testReadsLatestActivityAndFinalResponseDirectly() throws {
        let finalResponseAt = Int64(Date().timeIntervalSince1970) - 90
        let rolloutURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_complete", "task_started"],
            finalResponseAtUnixSeconds: finalResponseAt,
            finalResponseMessageSize: 128 * 1_024,
            testCase: self
        )
        var reader = RolloutActivityReader()

        let status = reader.load(
            at: rolloutURL.path,
            codexLaunchDate: .distantPast
        )

        XCTAssertEqual(status.runState, .running)
        XCTAssertEqual(status.lastFinalResponseAtUnixSeconds, finalResponseAt)
        XCTAssertEqual(status.lastFinalResponseMessage, String(repeating: "x", count: 128 * 1_024))
    }

    func testActivityBeforeApplicationLaunchIsIdle() throws {
        let rolloutURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_complete", "task_started"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 90,
            testCase: self
        )
        var reader = RolloutActivityReader()

        let status = reader.load(
            at: rolloutURL.path,
            codexLaunchDate: .distantFuture
        )

        XCTAssertEqual(status.runState, .idle)
        XCTAssertNotNil(status.lastFinalResponseAtUnixSeconds)
    }

    func testIgnoresHistoricalFinalResponseEmbeddedInCompaction() throws {
        let finalResponseAt = Int64(Date().timeIntervalSince1970) - 1_200
        let rolloutURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_started"],
            finalResponseAtUnixSeconds: finalResponseAt,
            compactionAtUnixSeconds: finalResponseAt + 1_000,
            testCase: self
        )
        var reader = RolloutActivityReader()

        let status = reader.load(
            at: rolloutURL.path,
            codexLaunchDate: .distantPast
        )

        XCTAssertEqual(status.lastFinalResponseAtUnixSeconds, finalResponseAt)
    }

    func testAbortedTurnIsIdle() throws {
        let rolloutURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_complete", "task_started", "turn_aborted"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 90,
            testCase: self
        )
        var reader = RolloutActivityReader()

        let status = reader.load(
            at: rolloutURL.path,
            codexLaunchDate: .distantPast
        )

        XCTAssertEqual(status.runState, .idle)
    }

    func testAppendedEventsReuseCachedHistoryWithoutLosingStatus() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-rollout-\(UUID().uuidString).jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8)
            .write(to: rolloutURL)
        let initialHandle = try FileHandle(forWritingTo: rolloutURL)
        try initialHandle.seekToEnd()
        try initialHandle.write(contentsOf: Data("\n".utf8))
        try initialHandle.close()
        addTeardownBlock { try? FileManager.default.removeItem(at: rolloutURL) }
        var reader = RolloutActivityReader()

        let initial = reader.load(
            at: rolloutURL.path,
            codexLaunchDate: .distantPast
        )
        XCTAssertEqual(initial.runState, .running)
        XCTAssertNil(initial.lastFinalResponseAtUnixSeconds)

        let finalResponseAt = Int64(Date().timeIntervalSince1970) - 10
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(finalResponseAt) + 0.4)
        )
        let appendedLines = """
        {"timestamp":"\(timestamp)","payload":{"phase":"final_answer"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}

        """
        let appendHandle = try FileHandle(forWritingTo: rolloutURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(appendedLines.utf8))
        try appendHandle.close()

        let updated = reader.load(
            at: rolloutURL.path,
            codexLaunchDate: .distantPast
        )

        XCTAssertEqual(updated.runState, .idle)
        XCTAssertEqual(updated.lastFinalResponseAtUnixSeconds, finalResponseAt)
        XCTAssertNil(updated.lastFinalResponseMessage)
    }
}
