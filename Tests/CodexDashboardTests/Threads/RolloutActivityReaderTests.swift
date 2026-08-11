import XCTest

@testable import CodexDashboard

final class RolloutActivityReaderTests: XCTestCase {
    func testPrunesCachedRolloutsOutsideCurrentCatalog() throws {
        let firstURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_started"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 20,
            testCase: self
        )
        let secondURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_complete"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 10,
            testCase: self
        )
        var reader = RolloutActivityReader()

        _ = reader.load(at: firstURL.path, codexLaunchDate: .distantPast)
        _ = reader.load(at: secondURL.path, codexLaunchDate: .distantPast)
        XCTAssertEqual(reader.cachedEntryCount, 2)

        reader.retainCache(for: [secondURL.path])

        XCTAssertEqual(reader.cachedEntryCount, 1)
    }

    func testReadsLatestLifecycleEventDirectly() throws {
        let rolloutURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_complete", "task_started"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 90,
            finalResponseMessageSize: 128 * 1_024,
            testCase: self
        )
        var reader = RolloutActivityReader()

        XCTAssertEqual(reader.load(at: rolloutURL.path, codexLaunchDate: .distantPast), .running)
    }

    func testLifecycleEventBeforeApplicationLaunchIsIdle() throws {
        let rolloutURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_complete", "task_started"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 90,
            testCase: self
        )
        var reader = RolloutActivityReader()

        XCTAssertEqual(reader.load(at: rolloutURL.path, codexLaunchDate: .distantFuture), .idle)
    }

    func testIgnoresHistoricalLifecycleEventEmbeddedInCompaction() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let completeTimestamp = formatter.string(from: now.addingTimeInterval(-2))
        let compactionTimestamp = formatter.string(from: now.addingTimeInterval(-1))
        let lines = [
            #"{"timestamp":"\#(completeTimestamp)","type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"timestamp":"\#(compactionTimestamp)","type":"compacted","replacement_history":[{"type":"event_msg","payload":{"type":"task_started"}}]}"#,
        ]
        let rolloutURL = try makeRollout(lines: lines)
        var reader = RolloutActivityReader()

        XCTAssertEqual(reader.load(at: rolloutURL.path, codexLaunchDate: .distantPast), .idle)
    }

    func testSkipsOversizedNonLifecycleLineWithoutLosingEarlierEvent() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let lines = [
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":"\#(String(repeating: "x", count: 1024 * 1024))"}"#,
        ]
        let rolloutURL = try makeRollout(lines: lines)
        var reader = RolloutActivityReader()

        XCTAssertEqual(reader.load(at: rolloutURL.path, codexLaunchDate: .distantPast), .running)
    }

    func testAbortedTurnIsIdle() throws {
        let rolloutURL = try CodexTestFixtures.makeRollout(
            lifecycleEvents: ["task_complete", "task_started", "turn_aborted"],
            finalResponseAtUnixSeconds: Int64(Date().timeIntervalSince1970) - 90,
            testCase: self
        )
        var reader = RolloutActivityReader()

        XCTAssertEqual(reader.load(at: rolloutURL.path, codexLaunchDate: .distantPast), .idle)
    }

    func testAppendedCompletionReusesCachedHistoryAndClearsRunningState() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startedTimestamp = formatter.string(from: Date().addingTimeInterval(-1))
        let rolloutURL = try makeRollout(lines: [
            #"{"timestamp":"\#(startedTimestamp)","type":"event_msg","payload":{"type":"task_started"}}"#,
        ])
        var reader = RolloutActivityReader()
        XCTAssertEqual(reader.load(at: rolloutURL.path, codexLaunchDate: .distantPast), .running)

        let completedTimestamp = formatter.string(from: Date())
        let appendHandle = try FileHandle(forWritingTo: rolloutURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(
            #"{"timestamp":"\#(completedTimestamp)","type":"event_msg","payload":{"type":"task_complete"}}"#.utf8
        ))
        try appendHandle.write(contentsOf: Data("\n".utf8))
        try appendHandle.close()

        XCTAssertEqual(reader.load(at: rolloutURL.path, codexLaunchDate: .distantPast), .idle)
    }

    private func makeRollout(lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-rollout-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
