import AppKit
import Foundation

@MainActor
final class RefreshScheduler {
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
    }

    private var catalogPollingTask: Task<Void, Never>?
    private var workingTreePollingTask: Task<Void, Never>?
    private var unreadPollingTask: Task<Void, Never>?
    private var accountUsagePollingTask: Task<Void, Never>?
    private var inactiveAccountUsagePollingTask: Task<Void, Never>?
    private let fileChanges: FileChangeMonitor?

    var hasFileChangeMonitoring: Bool { fileChanges != nil }

    init(observeFileChanges: Bool = true) {
        fileChanges = observeFileChanges ? FileChangeMonitor() : nil
    }

    deinit {
        catalogPollingTask?.cancel()
        workingTreePollingTask?.cancel()
        unreadPollingTask?.cancel()
        accountUsagePollingTask?.cancel()
        inactiveAccountUsagePollingTask?.cancel()
    }

    func start(
        synchronizeDashboard: @escaping @MainActor () async -> Void,
        updateWorkingTrees: @escaping @MainActor (Set<String>?) async -> Void,
        updateUnreadState: @escaping @MainActor () async -> Void,
        refreshAccountUsage: @escaping @MainActor () async -> Void,
        refreshInactiveAccountUsage: @escaping @MainActor () async -> Void,
        refreshAccountState: @escaping @MainActor () async -> Void
    ) {
        guard catalogPollingTask == nil,
              workingTreePollingTask == nil,
              unreadPollingTask == nil,
              accountUsagePollingTask == nil,
              inactiveAccountUsagePollingTask == nil
        else { return }

        catalogPollingTask = recurringTask(
            interval: { [self] in
                Schedule.catalog(
                    active: Self.isUserActive,
                    fileEventsAvailable: fileChanges != nil
                )
            },
            action: synchronizeDashboard
        )
        workingTreePollingTask = recurringTask(
            interval: { [self] in
                Schedule.workingTree(
                    active: Self.isUserActive,
                    fileEventsAvailable: fileChanges != nil
                )
            },
            action: { await updateWorkingTrees(nil) }
        )
        unreadPollingTask = recurringTask(
            interval: { [self] in
                Schedule.unread(
                    active: Self.isUserActive,
                    fileEventsAvailable: fileChanges != nil
                )
            },
            action: updateUnreadState
        )
        accountUsagePollingTask = recurringTask(
            interval: { Schedule.accountUsage },
            action: refreshAccountUsage
        )
        inactiveAccountUsagePollingTask = recurringTask(
            interval: { Schedule.inactiveAccountUsage },
            action: refreshInactiveAccountUsage
        )
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

    static var isUserActive: Bool {
        NSApp?.isActive == true
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexConfiguration.bundleIdentifier
    }

    private func recurringTask(
        interval: @escaping @MainActor () -> Duration,
        action: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: interval())
            }
        }
    }

    func stop() {
        catalogPollingTask?.cancel()
        workingTreePollingTask?.cancel()
        unreadPollingTask?.cancel()
        accountUsagePollingTask?.cancel()
        inactiveAccountUsagePollingTask?.cancel()
        catalogPollingTask = nil
        workingTreePollingTask = nil
        unreadPollingTask = nil
        accountUsagePollingTask = nil
        inactiveAccountUsagePollingTask = nil
        fileChanges?.stop()
    }
}
