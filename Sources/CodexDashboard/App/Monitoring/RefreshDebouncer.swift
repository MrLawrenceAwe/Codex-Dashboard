import Foundation

@MainActor
final class RefreshDebouncer {
    private let quietPeriod: Duration
    private let maximumDelay: Duration
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var generation: UInt64 = 0

    init(quietPeriod: Duration, maximumDelay: Duration) {
        self.quietPeriod = quietPeriod
        self.maximumDelay = maximumDelay
    }

    func schedule(_ refresh: @escaping @MainActor () async -> Void) {
        generation &+= 1
        guard task == nil else { return }
        let id = UUID()
        taskID = id
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var deadline = ContinuousClock.now + maximumDelay
            while !Task.isCancelled {
                let observedGeneration = generation
                let now = ContinuousClock.now
                if now < deadline {
                    try? await Task.sleep(for: min(quietPeriod, now.duration(to: deadline)))
                }
                guard !Task.isCancelled else { break }
                if generation != observedGeneration && ContinuousClock.now < deadline { continue }

                await refresh()
                guard !Task.isCancelled, generation != observedGeneration else { break }
                deadline = ContinuousClock.now + maximumDelay
            }
            if taskID == id {
                task = nil
                taskID = nil
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        taskID = nil
    }
}
