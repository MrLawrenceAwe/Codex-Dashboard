import Foundation

@MainActor
final class SynchronizationGate {
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var trailingSynchronizationRequested = false

    deinit { task?.cancel() }

    func perform(_ operation: @escaping @MainActor () async -> Void) async {
        if let task {
            trailingSynchronizationRequested = true
            await task.value
            return
        }
        while true {
            let id = UUID()
            let nextTask = Task { @MainActor in await operation() }
            task = nextTask
            taskID = id
            await nextTask.value
            guard taskID == id else { return }
            task = nil
            taskID = nil
            guard trailingSynchronizationRequested else { return }
            trailingSynchronizationRequested = false
        }
    }

    func cancel() async {
        let current = task
        task = nil
        taskID = nil
        trailingSynchronizationRequested = false
        current?.cancel()
        await current?.value
    }

    func stop() {
        task?.cancel()
        task = nil
        taskID = nil
        trailingSynchronizationRequested = false
    }
}
