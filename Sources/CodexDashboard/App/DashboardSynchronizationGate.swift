import Foundation

@MainActor
final class DashboardSynchronizationGate {
    private var task: Task<Void, Never>?
    private var taskID: UUID?

    deinit { task?.cancel() }

    func perform(_ operation: @escaping @MainActor () async -> Void) async {
        if let task {
            await task.value
            return
        }
        let id = UUID()
        let nextTask = Task { @MainActor in await operation() }
        task = nextTask
        taskID = id
        await nextTask.value
        if taskID == id {
            task = nil
            taskID = nil
        }
    }

    func cancel() async {
        let current = task
        task = nil
        taskID = nil
        current?.cancel()
        await current?.value
    }

    func stop() {
        task?.cancel()
        task = nil
        taskID = nil
    }
}
