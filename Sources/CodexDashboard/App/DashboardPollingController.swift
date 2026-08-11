import AppKit
import Foundation

@MainActor
final class DashboardPollingController {
    enum Schedule {
        static func catalog(active: Bool) -> Duration { active ? .seconds(2) : .seconds(8) }
        static func workingTree(active: Bool) -> Duration { active ? .seconds(2) : .seconds(10) }
        static func unread(active: Bool) -> Duration { active ? .milliseconds(500) : .seconds(1) }
    }

    private var catalogPollingTask: Task<Void, Never>?
    private var workingTreePollingTask: Task<Void, Never>?
    private var unreadPollingTask: Task<Void, Never>?
    private let fileChanges: DashboardFileChangeMonitor?

    init(observeFileChanges: Bool = true) {
        fileChanges = observeFileChanges ? DashboardFileChangeMonitor() : nil
    }

    deinit {
        catalogPollingTask?.cancel()
        workingTreePollingTask?.cancel()
        unreadPollingTask?.cancel()
    }

    func start(
        synchronizeDashboard: @escaping @MainActor () async -> Void,
        updateWorkingTrees: @escaping @MainActor (Set<String>?) async -> Void,
        updateUnreadState: @escaping @MainActor () async -> Void
    ) {
        guard catalogPollingTask == nil,
              workingTreePollingTask == nil,
              unreadPollingTask == nil
        else { return }

        catalogPollingTask = Task {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                await synchronizeDashboard()
                try? await clock.sleep(for: Schedule.catalog(active: Self.isUserActive))
            }
        }
        workingTreePollingTask = Task {
            while !Task.isCancelled {
                await updateWorkingTrees(nil)
                try? await Task.sleep(for: Schedule.workingTree(active: Self.isUserActive))
            }
        }
        unreadPollingTask = Task {
            while !Task.isCancelled {
                await updateUnreadState()
                try? await Task.sleep(for: Schedule.unread(active: Self.isUserActive))
            }
        }
        fileChanges?.start(
            catalogURL: CodexConfiguration.stateDatabaseURL,
            unreadStateURL: CodexConfiguration.globalStateURL,
            refreshCatalog: synchronizeDashboard,
            refreshUnread: updateUnreadState,
            refreshWorkingTrees: updateWorkingTrees
        )
    }

    func updateProjectPaths(_ paths: Set<String>) {
        fileChanges?.updateProjectPaths(paths)
    }

    private static var isUserActive: Bool {
        NSApp?.isActive == true
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexConfiguration.bundleIdentifier
    }

    func stop() {
        catalogPollingTask?.cancel()
        workingTreePollingTask?.cancel()
        unreadPollingTask?.cancel()
        catalogPollingTask = nil
        workingTreePollingTask = nil
        unreadPollingTask = nil
        fileChanges?.stop()
    }
}
