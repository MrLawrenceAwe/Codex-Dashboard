import Foundation

struct ThreadQuestionTracker {
    private var eventsByThreadID: [String: ThreadQuestionEvent] = [:]
    private var observationDate: Date?

    mutating func observeQuestions(
        in threads: [ThreadSummary],
        excluding excludedThreadIDs: Set<String> = [],
        observedAt currentDate: Date = .now
    ) -> String? {
        let latest = Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            thread.latestQuestionEvent.map { (thread.id, $0) }
        })
        defer {
            eventsByThreadID = latest
            observationDate = currentDate
        }
        guard let observationDate else { return nil }
        return threads.filter { thread in
            guard !excludedThreadIDs.contains(thread.id), !thread.originatesFromChromeExtension,
                  !thread.isScheduledAutomation,
                  let event = thread.latestQuestionEvent, event.id != nil else { return false }
            guard eventsByThreadID[thread.id] != nil || event.timestamp > observationDate else { return false }
            return eventsByThreadID[thread.id]?.id != event.id
        }.max { left, right in
            let leftDate = left.latestQuestionEvent!.timestamp
            let rightDate = right.latestQuestionEvent!.timestamp
            return leftDate == rightDate ? left.id < right.id : leftDate < rightDate
        }?.id
    }
}
