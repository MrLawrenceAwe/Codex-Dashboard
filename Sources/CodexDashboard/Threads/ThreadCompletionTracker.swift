import Foundation

struct ThreadCompletionTracker {
    struct Result {
        let hasCompletion: Bool
        let threadIDToOpen: String?
    }

    private var eventsByThreadID: [String: ThreadLifecycleEvent]?
    private var observationDate: Date?

    mutating func observeCompletions(
        in threads: [ThreadSummary],
        excluding excludedThreadIDs: Set<String> = [],
        observedAt currentDate: Date = .now
    ) -> Result {
        let latestEvents = Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            thread.latestLifecycleEvent.map { (thread.id, $0) }
        })
        let previousEvents = eventsByThreadID
        let previousDate = observationDate
        eventsByThreadID = latestEvents
        observationDate = currentDate
        guard let previousEvents, let previousDate else {
            return Result(hasCompletion: false, threadIDToOpen: nil)
        }

        let completions = threads.compactMap { thread -> (thread: ThreadSummary, timestamp: Date)? in
            guard
                let event = thread.latestLifecycleEvent,
                event.kind == .completed,
                previousEvents[thread.id] != event,
                previousEvents[thread.id] != nil || event.timestamp > previousDate
            else { return nil }
            return (thread, event.timestamp)
        }
        let newestEligible = completions.filter {
            !excludedThreadIDs.contains($0.thread.id) && $0.thread.allowsAutomaticOpening
        }.max { left, right in
            if left.timestamp == right.timestamp { return left.thread.id < right.thread.id }
            return left.timestamp < right.timestamp
        }?.thread.id
        return Result(hasCompletion: !completions.isEmpty, threadIDToOpen: newestEligible)
    }
}
