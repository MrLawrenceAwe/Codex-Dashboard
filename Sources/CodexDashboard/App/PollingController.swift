import AppKit
import Foundation

@MainActor
final class PollingController {
    enum Schedule {
        static func catalog(active: Bool, fileEventsAvailable: Bool) -> Duration {
            if fileEventsAvailable { return active ? .seconds(30) : .seconds(2 * 60) }
            return active ? .seconds(2) : .seconds(8)
        }
        static func workingTree(active: Bool, fileEventsAvailable: Bool) -> Duration {
            if fileEventsAvailable { return active ? .seconds(5 * 60) : .seconds(15 * 60) }
            return active ? .seconds(15) : .seconds(60)
        }
        static func unread(active: Bool, fileEventsAvailable: Bool) -> Duration {
            if fileEventsAvailable { return active ? .seconds(15) : .seconds(60) }
            return active ? .milliseconds(500) : .seconds(1)
        }
        static let accountUsage: Duration = .seconds(30)
        static let inactiveAccountUsage: Duration = .seconds(5 * 60)
        static func accountPopoverUnavailableRetry(active: Bool) -> Duration {
            active ? .seconds(10) : .seconds(60)
        }
    }

    private var catalogPollingTask: Task<Void, Never>?
    private var workingTreePollingTask: Task<Void, Never>?
    private var unreadPollingTask: Task<Void, Never>?
    private var accountUsagePollingTask: Task<Void, Never>?
    private var inactiveAccountUsagePollingTask: Task<Void, Never>?
    private var accountPopoverActionPollingTask: Task<Void, Never>?
    private let fileChanges: DataChangeMonitor?

    var hasFileChangeMonitoring: Bool { fileChanges != nil }

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
        handleAccountPopoverAction: @escaping @MainActor () async -> AccountPopoverActionHandlingOutcome,
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
                try? await clock.sleep(for: Schedule.catalog(
                    active: Self.isUserActive,
                    fileEventsAvailable: fileChanges != nil
                ))
            }
        }
        workingTreePollingTask = Task {
            while !Task.isCancelled {
                await updateWorkingTrees(nil)
                try? await Task.sleep(for: Schedule.workingTree(
                    active: Self.isUserActive,
                    fileEventsAvailable: fileChanges != nil
                ))
            }
        }
        unreadPollingTask = Task {
            while !Task.isCancelled {
                await updateUnreadState()
                try? await Task.sleep(for: Schedule.unread(
                    active: Self.isUserActive,
                    fileEventsAvailable: fileChanges != nil
                ))
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
            while !Task.isCancelled {
                let outcome = await handleAccountPopoverAction()
                if outcome == .unavailable {
                    try? await Task.sleep(for: Schedule.accountPopoverUnavailableRetry(
                        active: Self.isUserActive
                    ))
                }
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
