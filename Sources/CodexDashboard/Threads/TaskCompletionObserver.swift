import Foundation

struct TaskCompletion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let projectName: String
    let completedAt: Date
}

enum TaskCompletionBehavior: String, CaseIterable, Identifiable {
    case silent, notification, foreground

    var id: String { rawValue }
    var title: String {
        switch self {
        case .silent: "Silent badge"
        case .notification: "Notification"
        case .foreground: "Bring Codex to front"
        }
    }
}

struct TaskCompletionObserver {
    private var eventsByThreadID: [String: ThreadLifecycleEvent] = [:]
    private var observationDate: Date?

    mutating func recordSnapshotAndFindCompletions(
        in threads: [ThreadSummary],
        observedAt currentDate: Date = .now
    ) -> [TaskCompletion] {
        let previousDate = observationDate
        observationDate = currentDate
        var completions: [TaskCompletion] = []
        for thread in threads {
            guard let event = thread.latestLifecycleEvent else { continue }
            let previousEvent = eventsByThreadID[thread.id]
            // Keep the watermark when a task falls outside the current catalog.
            if let previousEvent, event.timestamp < previousEvent.timestamp { continue }
            eventsByThreadID[thread.id] = event
            guard let previousDate,
                  event.kind == .completed,
                  previousEvent != event,
                  previousEvent != nil || event.timestamp > previousDate else { continue }
            completions.append(TaskCompletion(
                id: thread.id, title: thread.title, projectName: thread.projectName,
                completedAt: event.timestamp
            ))
        }
        return completions.sorted {
            if $0.completedAt == $1.completedAt { return $0.id > $1.id }
            return $0.completedAt > $1.completedAt
        }
    }
}
