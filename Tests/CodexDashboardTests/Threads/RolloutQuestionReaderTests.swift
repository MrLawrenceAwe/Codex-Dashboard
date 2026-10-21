import XCTest

@testable import CodexDashboard

final class RolloutQuestionReaderTests: XCTestCase {
    private let asyncQuestion = #"{"timestamp":"2026-10-21T12:00:00Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"question-1","delivery":"async","questions":[{"title":"Which option?"}]}}}"#

    private func rollout(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAsyncQuestionSurvivesContinuedWorkAndTaskCompletion() throws {
        let url = try rollout([
            asyncQuestion,
            #"{"timestamp":"2026-10-21T12:00:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"reasoning"}}}"#,
            #"{"timestamp":"2026-10-21T12:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ])
        var reader = RolloutQuestionReader()
        XCTAssertEqual(reader.latestRecordedEvent(at: url.path)?.id, "question-1")
    }

    func testAppendReplyClearsQuestionAndNextQuestionIsDetected() throws {
        let url = try rollout([asyncQuestion])
        var reader = RolloutQuestionReader()
        XCTAssertEqual(reader.latestRecordedEvent(at: url.path)?.id, "question-1")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"timestamp":"2026-10-21T12:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Answer"}}"# + "\n").utf8))
        XCTAssertNil(reader.latestRecordedEvent(at: url.path)?.id)
        try handle.write(contentsOf: Data((asyncQuestion.replacingOccurrences(of: "question-1", with: "question-2") + "\n").utf8))
        XCTAssertEqual(reader.latestRecordedEvent(at: url.path)?.id, "question-2")
    }

    func testBlockingQuestionAndAnsweredToolOutput() throws {
        let call = #"{"timestamp":"2026-10-21T12:00:00Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"blocking-1","arguments":"{\"questions\":[{\"question\":\"Which?\"}]}"}}"#
        var reader = RolloutQuestionReader()
        let pending = try rollout([call])
        XCTAssertEqual(reader.latestRecordedEvent(at: pending.path)?.id, "blocking-1")
        let answered = try rollout([call, #"{"timestamp":"2026-10-21T12:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"blocking-1","output":"{\"answers\":{\"choice\":{\"answers\":[\"A\"]}}}"}}"#])
        XCTAssertNil(reader.latestRecordedEvent(at: answered.path)?.id)
    }

    func testIgnoresQuotedCallsCompactionAndOrdinaryMessages() throws {
        let url = try rollout([
            #"{"timestamp":"2026-10-21T12:00:00Z","type":"compacted","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"quoted","delivery":"async","questions":[{}]}}}"#,
            #"{"timestamp":"2026-10-21T12:00:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"text","delivery":"async","content":[{"type":"Text","text":"Is this request_user_input?"}]}}}"#,
        ])
        var reader = RolloutQuestionReader()
        XCTAssertNil(reader.latestRecordedEvent(at: url.path))
    }
}
