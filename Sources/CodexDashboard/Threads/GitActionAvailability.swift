import Foundation

/// A file edit latches the block, even if the edit is subsequently reverted.
/// Only a new successful response completion can accept another checkpoint.
actor GitActionAvailability {
    typealias FingerprintLoader = @Sendable (String) async -> String?

    private struct Checkpoint {
        let path: String
        let completion: ThreadLifecycleEvent
        let fingerprint: String
        var blocked = false
    }

    private var checkpoints: [String: Checkpoint] = [:]
    private let fingerprint: FingerprintLoader

    init(fingerprint: @escaping FingerprintLoader = { await GitWorktreeFingerprint.load(at: $0) }) {
        self.fingerprint = fingerprint
    }

    func apply(to threads: [ThreadSummary], events: [String: ThreadLifecycleEvent]) async -> [ThreadSummary] {
        let ids = Set(threads.map(\.id))
        checkpoints = checkpoints.filter { ids.contains($0.key) }
        var fingerprints: [String: String] = [:]
        var checkedPaths: Set<String> = []
        var result: [ThreadSummary] = []
        for var thread in threads {
            guard thread.sharesGroupRepository, let path = thread.projectGroupPath else {
                result.append(thread)
                continue
            }
            let event = events[thread.id]
            if checkpoints[thread.id]?.path != path { checkpoints[thread.id] = nil }
            let newCompletion = event?.kind == .completed && checkpoints[thread.id]?.completion != event
            let needsRead = newCompletion || checkpoints[thread.id]?.blocked == false
            if needsRead, checkedPaths.insert(path).inserted {
                fingerprints[path] = await fingerprint(path)
            }
            if newCompletion, let event, let current = fingerprints[path] {
                checkpoints[thread.id] = Checkpoint(path: path, completion: event, fingerprint: current)
            } else if needsRead, var checkpoint = checkpoints[thread.id] {
                checkpoint.blocked = fingerprints[path] != checkpoint.fingerprint
                checkpoints[thread.id] = checkpoint
            }
            thread.gitActionsBlockedUntilCompletion = checkpoints[thread.id]?.blocked ?? true
            result.append(thread)
        }
        return result
    }
}
