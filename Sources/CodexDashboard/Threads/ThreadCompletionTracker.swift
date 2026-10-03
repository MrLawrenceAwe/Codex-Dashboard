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

        let completions = latestEvents.compactMap { threadID, event -> (threadID: String, event: ThreadLifecycleEvent)? in
            guard
                event.kind == .completed,
                previousEvents[threadID] != event,
                previousEvents[threadID] != nil || event.timestamp > previousDate
            else { return nil }
            return (threadID, event)
        }
        let newestEligible = completions.filter { !excludedThreadIDs.contains($0.threadID) }.max { left, right in
            if left.event.timestamp == right.event.timestamp { return left.threadID < right.threadID }
            return left.event.timestamp < right.event.timestamp
        }?.threadID
        return Result(hasCompletion: !completions.isEmpty, threadIDToOpen: newestEligible)
    }
}
