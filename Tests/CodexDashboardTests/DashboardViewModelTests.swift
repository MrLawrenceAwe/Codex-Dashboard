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
            dashboardHostFactory: { StubDashboardHost() }
        )

        XCTAssertEqual(viewModel.connectionState, .checking)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.threads, [thread])
        XCTAssertEqual(viewModel.availableThreadCount, 4)
        XCTAssertEqual(viewModel.connectionState, .appClosed)
        XCTAssertEqual(viewModel.statusPresentation.title, "Codex is closed")
    }
}
