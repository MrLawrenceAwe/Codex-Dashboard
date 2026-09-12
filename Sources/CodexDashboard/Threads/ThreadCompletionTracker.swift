import Foundation

struct ThreadCompletionTracker {
    private var eventsByThreadID: [String: ThreadLifecycleEvent]?
    private var observationDate: Date?

    mutating func recordSnapshotAndFindNewestCompletion(
        in threads: [ThreadSummary],
        observedAt currentDate: Date = .now
    ) -> String? {
        let latestEvents = Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            thread.latestLifecycleEvent.map { (thread.id, $0) }
        })
        let previousEvents = eventsByThreadID
        let previousDate = observationDate
        eventsByThreadID = latestEvents
        observationDate = currentDate
        guard let previousEvents, let previousDate else { return nil }

        return latestEvents.compactMap { threadID, event -> (String, ThreadLifecycleEvent)? in
            guard
                event.kind == .completed,
                previousEvents[threadID] != event,
                previousEvents[threadID] != nil || event.timestamp > previousDate
            else { return nil }
            return (threadID, event)
        }.max { left, right in
            if left.1.timestamp == right.1.timestamp { return left.0 < right.0 }
            return left.1.timestamp < right.1.timestamp
        }?.0
    }
}
