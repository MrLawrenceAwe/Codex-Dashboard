import AppKit
import Foundation

@MainActor
final class RefreshScheduler {
    enum Schedule {
        static func catalog(active: Bool) -> Duration {
            active ? .seconds(2) : .seconds(8)
        }
        static func projectGitStatus(active: Bool) -> Duration {
            return active ? .seconds(15) : .seconds(60)
        }
        static func unread(active: Bool, fileChangeMonitoringConfigured: Bool) -> Duration {
            if fileChangeMonitoringConfigured { return active ? .seconds(15) : .seconds(60) }
            return active ? .milliseconds(500) : .seconds(1)
        }
        static func accountUsage(active: Bool) -> Duration {
            active ? .seconds(2 * 60) : .seconds(15 * 60)
        }
        static let inactiveAccountUsage: Duration = .seconds(5 * 60)
    }

    private var catalogPollingTask: Task<Void, Never>?
    private var projectGitPollingTask: Task<Void, Never>?
    private var unreadPollingTask: Task<Void, Never>?
    private var accountUsagePollingTask: Task<Void, Never>?
    private var inactiveAccountUsagePollingTask: Task<Void, Never>?
    private let dataChanges: CodexDataChangeMonitor?
    private let projectGitChanges: ProjectGitChangeMonitor?

    var isFileChangeMonitoringConfigured: Bool { dataChanges != nil }

    init(observeFileChanges: Bool = true) {
        dataChanges = observeFileChanges ? CodexDataChangeMonitor() : nil
        projectGitChanges = observeFileChanges ? ProjectGitChangeMonitor() : nil
    }

    deinit {
        catalogPollingTask?.cancel()
        projectGitPollingTask?.cancel()
        unreadPollingTask?.cancel()
        accountUsagePollingTask?.cancel()
        inactiveAccountUsagePollingTask?.cancel()
    }

    func start(
        synchronizeDashboard: @escaping @MainActor () async -> Void,
        updateProjectGitStatuses: @escaping @MainActor (Set<String>?) async -> Void,
        updateUnreadState: @escaping @MainActor () async -> Void,
        refreshAccountUsage: @escaping @MainActor () async -> Void,
        refreshInactiveAccountUsage: @escaping @MainActor () async -> Void,
        refreshAccountState: @escaping @MainActor () async -> Void
    ) {
        guard catalogPollingTask == nil,
              projectGitPollingTask == nil,
              unreadPollingTask == nil,
              accountUsagePollingTask == nil,
              inactiveAccountUsagePollingTask == nil
        else { return }

        catalogPollingTask = recurringTask(
            interval: {
                Schedule.catalog(active: Self.isDashboardOrCodexForeground)
            },
            action: synchronizeDashboard
        )
        projectGitPollingTask = recurringTask(
            interval: { Schedule.projectGitStatus(active: Self.isDashboardOrCodexForeground) },
            action: { await updateProjectGitStatuses(nil) }
        )
        unreadPollingTask = recurringTask(
            interval: { [self] in
                Schedule.unread(
                    active: Self.isDashboardOrCodexForeground,
                    fileChangeMonitoringConfigured: isFileChangeMonitoringConfigured
                )
            },
            action: updateUnreadState
        )
        accountUsagePollingTask = recurringTask(
            interval: { Self.Schedule.accountUsage(active: Self.isDashboardOrCodexForeground) },
            action: {
                guard Self.isDashboardOrCodexForeground else { return }
                await refreshAccountUsage()
            }
        )
        inactiveAccountUsagePollingTask = recurringTask(
            interval: { Schedule.inactiveAccountUsage },
            action: refreshInactiveAccountUsage
        )
        projectGitChanges?.start(refreshProjectGitStatuses: updateProjectGitStatuses)
        dataChanges?.start(
            catalogURL: CodexConfiguration.stateDatabaseURL,
            unreadStateURL: CodexConfiguration.globalStateURL,
            accountMetadataURL: CodexConfiguration.accountMetadataURL,
            authenticationURL: CodexConfiguration.authenticationURL,
            refreshCatalog: synchronizeDashboard,
            refreshUnread: updateUnreadState,
            refreshAccounts: refreshAccountState
        )
    }

    func updateProjectPaths(_ paths: Set<String>) {
        projectGitChanges?.updateProjectPaths(paths)
    }

    static var isDashboardOrCodexForeground: Bool {
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
        projectGitPollingTask?.cancel()
        unreadPollingTask?.cancel()
        accountUsagePollingTask?.cancel()
        inactiveAccountUsagePollingTask?.cancel()
        catalogPollingTask = nil
        projectGitPollingTask = nil
        unreadPollingTask = nil
        accountUsagePollingTask = nil
        inactiveAccountUsagePollingTask = nil
        dataChanges?.stop()
        projectGitChanges?.stop()
    }
}
