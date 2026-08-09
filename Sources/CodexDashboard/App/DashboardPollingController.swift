import Foundation

@MainActor
final class DashboardPollingController {
    private enum Schedule {
        static let catalog: Duration = .seconds(2)
        static let workingTree: Duration = .seconds(10)
        static let unread: Duration = .milliseconds(500)
    }

    private var catalogPollingTask: Task<Void, Never>?
    private var workingTreePollingTask: Task<Void, Never>?
    private var unreadPollingTask: Task<Void, Never>?

    deinit {
        catalogPollingTask?.cancel()
        workingTreePollingTask?.cancel()
        unreadPollingTask?.cancel()
    }

    func start(
        synchronizeDashboard: @escaping @MainActor () async -> Void,
        updateWorkingTrees: @escaping @MainActor () async -> Void,
        updateUnreadState: @escaping @MainActor () async -> Void
    ) {
        guard catalogPollingTask == nil,
              workingTreePollingTask == nil,
              unreadPollingTask == nil
        else { return }

        catalogPollingTask = Task {
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                await synchronizeDashboard()
                deadline += Schedule.catalog
                if deadline < clock.now { deadline = clock.now }
                try? await clock.sleep(until: deadline)
            }
        }
        workingTreePollingTask = Task {
            while !Task.isCancelled {
                await updateWorkingTrees()
                try? await Task.sleep(for: Schedule.workingTree)
            }
        }
        unreadPollingTask = Task {
            while !Task.isCancelled {
                await updateUnreadState()
                try? await Task.sleep(for: Schedule.unread)
            }
        }
    }

    func stop() {
        catalogPollingTask?.cancel()
        workingTreePollingTask?.cancel()
        unreadPollingTask?.cancel()
        catalogPollingTask = nil
        workingTreePollingTask = nil
        unreadPollingTask = nil
    }
}
