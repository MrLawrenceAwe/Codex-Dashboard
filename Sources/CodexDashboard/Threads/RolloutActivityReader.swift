import Foundation

struct RolloutActivityReader {
    static let startedEventType = "task_started"
    static let endedEventTypes = ["task_complete", "turn_aborted"]
    static let finalResponsePhase = "final_answer"
    static let lifecycleEventTypes = [startedEventType] + endedEventTypes

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Failure: Decodable {
                let codexErrorInfo: String?

                private enum CodingKeys: String, CodingKey {
                    case codexErrorInfo = "codex_error_info"
                }
            }

            let type: String?
            let error: Failure?
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private var records = RolloutRecordReader<ThreadLifecycleEvent>(inspect: Self.inspect)

    var cachedEntryCount: Int { records.cachedEntryCount }

    mutating func retainCache(for paths: Set<String>) {
        records.retainCache(for: paths)
    }

    mutating func latestRecordedEvent(at path: String) -> ThreadLifecycleEvent? {
        records.latestRecordedEvent(at: path)
    }

    private static func inspect(
        _ lineData: Data
    ) -> ThreadLifecycleEvent? {
        guard
            lifecycleEventTypes.contains(where: { lineData.range(of: Data($0.utf8)) != nil }),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: lineData),
            envelope.type == "event_msg",
            let payloadType = envelope.payload?.type,
            let timestamp = envelope.timestamp,
            let date = try? Date(
                timestamp,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: timestamp.contains("."))
            )
        else { return nil }
        let kind: ThreadLifecycleEventKind
        switch payloadType {
        case Self.startedEventType: kind = .started
        case "task_complete":
            kind = envelope.payload?.error?.codexErrorInfo == "usage_limit_exceeded"
                ? .usageLimitReached
                : .completed
        case "turn_aborted": kind = .aborted
        default: return nil
        }
        return ThreadLifecycleEvent(kind: kind, timestamp: date)
    }
}
