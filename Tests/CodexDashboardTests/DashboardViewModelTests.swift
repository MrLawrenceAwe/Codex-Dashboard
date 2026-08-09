import XCTest

@testable import CodexDashboard

private struct StubThreadRepository: ThreadSnapshotLoading {
    let snapshot: ThreadSnapshot

    func loadSnapshot(
        gitWorkingTreeStatuses: [String: GitWorkingTreeStatus],
        activeApplicationLaunchDate: Date?
    ) async throws -> ThreadSnapshot {
        snapshot
    }
}

private struct StubGitStatusLoader: GitWorkingTreeStatusLoading {
    func load(at workspacePaths: Set<String>) async -> [String: GitWorkingTreeStatus] {
        [:]
    }
}

private struct StubUnreadStateLoader: UnreadStateLoading {
    let unreadThreadIDs: Set<String>

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }
}

private actor MutableUnreadStateLoader: UnreadStateLoading {
    private var unreadThreadIDs: Set<String> = []

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }

    func setUnreadThreadIDs(_ threadIDs: Set<String>) {
        unreadThreadIDs = threadIDs
    }
}

@MainActor
private final class StubDashboardHost: DashboardHost {
    let applicationIsRunning = false
    let applicationLaunchDate: Date? = nil
    let keepsDashboardMounted = false

    func mainRendererTargets() async -> [DevToolsTarget] { [] }
    func prepareForRestart() {}
    func restartApplication() async throws -> [DevToolsTarget] { [] }
    func mountDashboard(
        with payload: DashboardPayload,
        on targets: [DevToolsTarget],
        force: Bool
    ) async throws {}
    func disableDashboard() async throws -> DashboardDisableResult { .applicationClosed }
    func openDashboard() async {}
}

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testRefreshUsesInjectedDependenciesWithoutStartingPolling() async {
        let thread = DashboardThread(
            id: "thread-1",
            title: "Injected thread",
            preview: "Preview",
            workspaceName: "Project",
            workspacePath: "/tmp/project",
            recencyTimestamp: 1,
            isPinned: false,
            model: nil,
            activity: .idle,
            gitWorkingTreeStatus: .clean
        )
        let viewModel = DashboardViewModel(
            threadRepository: StubThreadRepository(
                snapshot: ThreadSnapshot(threads: [thread], availableThreadCount: 4)
            ),
            gitStatusLoader: StubGitStatusLoader(),
            unreadStateLoader: StubUnreadStateLoader(unreadThreadIDs: [thread.id]),
            dashboardHostFactory: { StubDashboardHost() }
        )

        XCTAssertEqual(viewModel.connectionState, .checking)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.threads.first?.isUnread == true)
        XCTAssertEqual(viewModel.availableThreadCount, 4)
        XCTAssertEqual(viewModel.connectionState, .appClosed)
        XCTAssertEqual(viewModel.statusPresentation.title, "Codex is closed")
    }

    func testUnreadPollingUpdatesThreadWithinBoundedInterval() async throws {
        let thread = DashboardThread(
            id: "thread-1",
            title: "Thread",
            preview: "Preview",
            workspaceName: "Project",
            workspacePath: "/tmp/project",
            recencyTimestamp: 1,
            isPinned: false,
            model: nil,
            activity: .idle,
            gitWorkingTreeStatus: .clean
        )
        let unreadStateLoader = MutableUnreadStateLoader()
        let viewModel = DashboardViewModel(
            threadRepository: StubThreadRepository(
                snapshot: ThreadSnapshot(threads: [thread], availableThreadCount: 1)
            ),
            gitStatusLoader: StubGitStatusLoader(),
            unreadStateLoader: unreadStateLoader,
            dashboardHostFactory: { StubDashboardHost() }
        )
        viewModel.startRefreshing()
        defer { viewModel.stopRefreshing() }

        try await waitUntil { viewModel.threads.count == 1 }
        await unreadStateLoader.setUnreadThreadIDs([thread.id])
        try await waitUntil { viewModel.threads.first?.isUnread == true }

        XCTAssertTrue(viewModel.threads.first?.isUnread == true)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition())
    }
}
