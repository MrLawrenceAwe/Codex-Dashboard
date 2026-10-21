import Foundation

struct ThreadQuestionEvent: Codable, Equatable, Sendable {
    // A nil ID records a user reply or interruption, clearing the preceding question.
    let id: String?
    let timestamp: Date
}

struct RolloutQuestionReader {
    private var records = RolloutRecordReader<ThreadQuestionEvent>(inspect: Self.inspect)

    mutating func retainCache(for paths: Set<String>) {
        records.retainCache(for: paths)
    }

    mutating func latestRecordedEvent(at path: String) -> ThreadQuestionEvent? {
        records.latestRecordedEvent(at: path)
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Item: Decodable {
                let type: String?
                let id: String?
                let delivery: String?
                let questions: [Question]?
            }
            struct Question: Decodable {}
            let type: String?
            let item: Item?
            let name: String?
            let call_id: String?
            let arguments: String?
            let output: String?
        }
        let timestamp: String
        let type: String
        let payload: Payload
    }

    private static func inspect(_ data: Data) -> ThreadQuestionEvent? {
        let markers = ["item_completed", "request_user_input", "user_message", "turn_aborted", "task_started", "function_call_output"]
        guard markers.contains(where: { data.range(of: Data($0.utf8)) != nil }),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let timestamp = try? Date(
                envelope.timestamp,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: envelope.timestamp.contains("."))
              ) else { return nil }
        let payload = envelope.payload
        if envelope.type == "event_msg" {
            if ["user_message", "turn_aborted", "task_started", "function_call_output"].contains(payload.type) {
                return ThreadQuestionEvent(id: nil, timestamp: timestamp)
            }
            if payload.type == "item_completed", let item = payload.item,
               item.type == "AgentMessage", item.delivery == "async",
               item.questions?.isEmpty == false, let id = item.id {
                return ThreadQuestionEvent(id: id, timestamp: timestamp)
            }
        }
        if envelope.type == "response_item", payload.type == "function_call_output",
           let output = payload.output?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
           object["answers"] is [String: Any] {
            return ThreadQuestionEvent(id: nil, timestamp: timestamp)
        }
        // Blocking questions have a tool call rather than an async AgentMessage.
        if envelope.type == "response_item", payload.type == "function_call",
           payload.name == "request_user_input", let id = payload.call_id,
           let arguments = payload.arguments?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
           let questions = object["questions"] as? [Any], !questions.isEmpty {
            return ThreadQuestionEvent(id: id, timestamp: timestamp)
        }
        return nil
    }
}
