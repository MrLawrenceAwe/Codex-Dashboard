import Foundation

@MainActor
final class DashboardRefreshCoordinator {
    private enum Schedule {
        static let threads: Duration = .seconds(2)
        static let git: Duration = .seconds(10)
        static let unread: Duration = .milliseconds(500)
    }

    private var threadTask: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?
    private var unreadTask: Task<Void, Never>?

    deinit {
        threadTask?.cancel()
        gitTask?.cancel()
        unreadTask?.cancel()
    }

    func start(
        refreshThreads: @escaping @MainActor () async -> Void,
        refreshGit: @escaping @MainActor () async -> Void,
        refreshUnread: @escaping @MainActor () async -> Void
    ) {
        guard threadTask == nil, gitTask == nil, unreadTask == nil else { return }

        threadTask = Task {
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                await refreshThreads()
                deadline += Schedule.threads
                if deadline < clock.now { deadline = clock.now }
                try? await clock.sleep(until: deadline)
            }
        }
        gitTask = Task {
            while !Task.isCancelled {
                await refreshGit()
                try? await Task.sleep(for: Schedule.git)
            }
        }
        unreadTask = Task {
            while !Task.isCancelled {
                await refreshUnread()
                try? await Task.sleep(for: Schedule.unread)
            }
        }
    }

    func stop() {
        threadTask?.cancel()
        gitTask?.cancel()
        unreadTask?.cancel()
        threadTask = nil
        gitTask = nil
        unreadTask = nil
    }
}
