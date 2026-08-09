import XCTest

@testable import CodexDashboard

private struct StubThreadRepository: ThreadSnapshotLoading {
    let snapshot: ThreadSnapshot

    func loadSnapshot(
        gitStatuses: [String: WorkspaceGitStatus],
        activeApplicationLaunchDate: Date?
    ) async throws -> ThreadSnapshot {
        snapshot
    }
}

private struct StubGitStatusLoader: WorkspaceGitStatusLoading {
    func load(at workspacePaths: Set<String>) async -> [String: WorkspaceGitStatus] {
        [:]
    }
}

@MainActor
private final class StubHostSession: DashboardHosting {
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
            workspace: "Project",
            workspacePath: "/tmp/project",
            updatedAtUnixSeconds: 1,
            isPinned: false,
            model: nil,
            activity: .idle,
            gitStatus: .clean
        )
        let viewModel = DashboardViewModel(
            threadRepository: StubThreadRepository(
                snapshot: ThreadSnapshot(threads: [thread], totalThreadCount: 4)
            ),
            gitStatusLoader: StubGitStatusLoader(),
            hostSessionFactory: { StubHostSession() }
        )

        XCTAssertEqual(viewModel.sessionState, .checking)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.threads, [thread])
        XCTAssertEqual(viewModel.totalThreadCount, 4)
        XCTAssertEqual(viewModel.sessionState, .appClosed)
        XCTAssertEqual(viewModel.statusPresentation.title, "Codex is closed")
    }
}
