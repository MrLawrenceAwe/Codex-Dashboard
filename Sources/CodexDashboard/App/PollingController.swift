import AppKit
import Foundation

@MainActor
final class PollingController {
    enum Schedule {
        static func catalog(active: Bool) -> Duration { active ? .seconds(2) : .seconds(8) }
        static func workingTree(active: Bool) -> Duration { active ? .seconds(15) : .seconds(60) }
        static func unread(active: Bool) -> Duration { active ? .milliseconds(500) : .seconds(1) }
        static let accountUsage: Duration = .seconds(30)
        static let inactiveAccountUsage: Duration = .seconds(5 * 60)
        static func accountPopover(panelOpen: Bool, active: Bool) -> Duration {
            if panelOpen { return .milliseconds(250) }
            return active ? .seconds(2) : .seconds(8)
        }
    }

    private var catalogPollingTask: Task<Void, Never>?
    private var workingTreePollingTask: Task<Void, Never>?
    private var unreadPollingTask: Task<Void, Never>?
    private var accountUsagePollingTask: Task<Void, Never>?
    private var inactiveAccountUsagePollingTask: Task<Void, Never>?
    private var accountPopoverActionPollingTask: Task<Void, Never>?
    private let fileChanges: DataChangeMonitor?

    init(observeFileChanges: Bool = true) {
        fileChanges = observeFileChanges ? DataChangeMonitor() : nil
    }

    deinit {
        catalogPollingTask?.cancel()
        workingTreePollingTask?.cancel()
        unreadPollingTask?.cancel()
        accountUsagePollingTask?.cancel()
        inactiveAccountUsagePollingTask?.cancel()
        accountPopoverActionPollingTask?.cancel()
    }

    func start(
        synchronizeDashboard: @escaping @MainActor () async -> Void,
        updateWorkingTrees: @escaping @MainActor (Set<String>?) async -> Void,
        updateUnreadState: @escaping @MainActor () async -> Void,
        refreshAccountUsage: @escaping @MainActor () async -> Void,
        refreshInactiveAccountUsage: @escaping @MainActor () async -> Void,
        handleAccountPopoverAction: @escaping @MainActor () async -> Bool,
        refreshAccountState: @escaping @MainActor () async -> Void
    ) {
        guard catalogPollingTask == nil,
              workingTreePollingTask == nil,
              unreadPollingTask == nil,
              accountUsagePollingTask == nil,
              inactiveAccountUsagePollingTask == nil,
              accountPopoverActionPollingTask == nil
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
        accountUsagePollingTask = Task {
            while !Task.isCancelled {
                await refreshAccountUsage()
                try? await Task.sleep(for: Schedule.accountUsage)
            }
        }
        inactiveAccountUsagePollingTask = Task {
            while !Task.isCancelled {
                await refreshInactiveAccountUsage()
                try? await Task.sleep(for: Schedule.inactiveAccountUsage)
            }
        }
        accountPopoverActionPollingTask = Task {
            var panelOpen = false
            while !Task.isCancelled {
                panelOpen = await handleAccountPopoverAction()
                try? await Task.sleep(for: Schedule.accountPopover(
                    panelOpen: panelOpen,
                    active: Self.isUserActive
                ))
            }
        }
        fileChanges?.start(
            catalogURL: CodexConfiguration.stateDatabaseURL,
            unreadStateURL: CodexConfiguration.globalStateURL,
            accountMetadataURL: CodexConfiguration.accountMetadataURL,
            authenticationURL: CodexConfiguration.authenticationURL,
            refreshCatalog: synchronizeDashboard,
            refreshUnread: updateUnreadState,
            refreshAccounts: refreshAccountState,
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
        accountUsagePollingTask?.cancel()
        inactiveAccountUsagePollingTask?.cancel()
        accountPopoverActionPollingTask?.cancel()
        catalogPollingTask = nil
        workingTreePollingTask = nil
        unreadPollingTask = nil
        accountUsagePollingTask = nil
        inactiveAccountUsagePollingTask = nil
        accountPopoverActionPollingTask = nil
        fileChanges?.stop()
    }
}
