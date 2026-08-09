import XCTest

@testable import CodexDashboard

final class RolloutStatusReaderTests: XCTestCase {
    func testReadsLatestActivityAndFinalResponseDirectly() throws {
        let finalResponseAt = Int64(Date().timeIntervalSince1970) - 90
        let rolloutURL = try TestDatabaseFactory.makeRollout(
            lifecycleEvents: ["task_complete", "task_started"],
            finalResponseAtUnixSeconds: finalResponseAt,
            finalResponseMessageSize: 128 * 1_024,
            testCase: self
        )
        var reader = RolloutStatusReader()

        let status = reader.load(
            at: rolloutURL.path,
            activeApplicationLaunchDate: .distantPast
        )

        XCTAssertEqual(status.activity, .running)
        XCTAssertEqual(status.lastFinalResponseAtUnixSeconds, finalResponseAt)
    }

    func testActivityBeforeApplicationLaunchIsIdle() throws {
        let rolloutURL = try TestDatabaseFactory.makeRollout(
            lifecycleEvents: ["task_complete", "task_started"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 90,
            testCase: self
        )
        var reader = RolloutStatusReader()

        let status = reader.load(
            at: rolloutURL.path,
            activeApplicationLaunchDate: .distantFuture
        )

        XCTAssertEqual(status.activity, .idle)
        XCTAssertNotNil(status.lastFinalResponseAtUnixSeconds)
    }

    func testIgnoresHistoricalFinalResponseEmbeddedInCompaction() throws {
        let finalResponseAt = Int64(Date().timeIntervalSince1970) - 1_200
        let rolloutURL = try TestDatabaseFactory.makeRollout(
            lifecycleEvents: ["task_started"],
            finalResponseAtUnixSeconds: finalResponseAt,
            compactionAtUnixSeconds: finalResponseAt + 1_000,
            testCase: self
        )
        var reader = RolloutStatusReader()

        let status = reader.load(
            at: rolloutURL.path,
            activeApplicationLaunchDate: .distantPast
        )

        XCTAssertEqual(status.lastFinalResponseAtUnixSeconds, finalResponseAt)
    }

    func testAbortedTurnIsIdle() throws {
        let rolloutURL = try TestDatabaseFactory.makeRollout(
            lifecycleEvents: ["task_complete", "task_started", "turn_aborted"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 90,
            testCase: self
        )
        var reader = RolloutStatusReader()

        let status = reader.load(
            at: rolloutURL.path,
            activeApplicationLaunchDate: .distantPast
        )

        XCTAssertEqual(status.activity, .idle)
    }
}
