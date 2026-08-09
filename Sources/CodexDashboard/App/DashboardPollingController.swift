import AppKit
import Foundation

@MainActor
final class DashboardPollingController {
    private enum Schedule {
        static func catalog(active: Bool) -> Duration { active ? .seconds(2) : .seconds(8) }
        static func workingTree(active: Bool) -> Duration { active ? .seconds(10) : .seconds(30) }
        static func unread(active: Bool) -> Duration { active ? .milliseconds(500) : .seconds(1) }
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
            while !Task.isCancelled {
                await synchronizeDashboard()
                try? await clock.sleep(for: Schedule.catalog(active: Self.isUserActive))
            }
        }
        workingTreePollingTask = Task {
            while !Task.isCancelled {
                await updateWorkingTrees()
                try? await Task.sleep(for: Schedule.workingTree(active: Self.isUserActive))
            }
        }
        unreadPollingTask = Task {
            while !Task.isCancelled {
                await updateUnreadState()
                try? await Task.sleep(for: Schedule.unread(active: Self.isUserActive))
            }
        }
    }

    private static var isUserActive: Bool {
        NSApp.isActive
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexConfiguration.bundleIdentifier
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
