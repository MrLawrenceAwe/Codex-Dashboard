import XCTest

@testable import CodexDashboard

private struct StubCatalogProvider: ThreadCatalogProviding {
    let catalog: ThreadCatalog

    func loadCatalog(
        gitStatuses: [String: GitStatus],
        codexLaunchDate: Date?
    ) async throws -> ThreadCatalog {
        catalog
    }
}

private struct StubGitStatusProvider: GitStatusProviding {
    func load(projectPaths: Set<String>) async -> [String: GitStatus] {
        [:]
    }
}

private struct StubUnreadIDProvider: UnreadThreadIDProviding {
    let unreadThreadIDs: Set<String>

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }
}

private actor MutableUnreadIDProvider: UnreadThreadIDProviding {
    private var unreadThreadIDs: Set<String> = []

    func loadUnreadThreadIDs() async throws -> Set<String> {
        unreadThreadIDs
    }

    func setUnreadThreadIDs(_ threadIDs: Set<String>) {
        unreadThreadIDs = threadIDs
    }
}

@MainActor
private final class StubDashboardRuntime: DashboardRuntime {
    let codexIsRunning = false
    let codexLaunchDate: Date? = nil
    let maintainsDashboard = false

    func rendererTargets() async -> [DevToolsTarget] { [] }
    func prepareForRestart() {}
    func restartCodex() async throws -> [DevToolsTarget] { [] }
    func synchronizeDashboard(
        with snapshot: RendererSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws {}
    func disableDashboard() async throws -> DashboardDisableOutcome { .codexClosed }
    func openDashboard() async {}
}

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testRefreshUsesInjectedDependenciesWithoutStartingPolling() async {
        let thread = ThreadSummary(
            id: "thread-1",
            title: "Injected thread",
            preview: "Preview",
            projectName: "Project",
            projectPath: "/tmp/project",
            sortTimestamp: 1,
            isPinned: false,
            model: nil,
            runState: .idle,
            gitStatus: .clean
        )
        let viewModel = DashboardViewModel(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 4)
            ),
            gitStatusProvider: StubGitStatusProvider(),
            unreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: [thread.id]),
            runtimeFactory: { StubDashboardRuntime() }
        )

        XCTAssertEqual(viewModel.connectionState, .checking)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.threads.first?.isUnread == true)
        XCTAssertEqual(viewModel.totalThreadCount, 4)
        XCTAssertEqual(viewModel.connectionState, .appClosed)
        XCTAssertEqual(viewModel.statusPresentation.title, "Codex is closed")
    }

    func testUnreadPollingUpdatesThreadWithinBoundedInterval() async throws {
        let thread = ThreadSummary(
            id: "thread-1",
            title: "Thread",
            preview: "Preview",
            projectName: "Project",
            projectPath: "/tmp/project",
            sortTimestamp: 1,
            isPinned: false,
            model: nil,
            runState: .idle,
            gitStatus: .clean
        )
        let unreadIDProvider = MutableUnreadIDProvider()
        let viewModel = DashboardViewModel(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(threads: [thread], totalThreadCount: 1)
            ),
            gitStatusProvider: StubGitStatusProvider(),
            unreadIDProvider: unreadIDProvider,
            runtimeFactory: { StubDashboardRuntime() }
        )
        viewModel.startRefreshing()
        defer { viewModel.stopRefreshing() }

        try await waitUntil { viewModel.threads.count == 1 }
        await unreadIDProvider.setUnreadThreadIDs([thread.id])
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
