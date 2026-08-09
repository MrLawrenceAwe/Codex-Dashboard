import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class ThreadDashboardWebTests: SerializedDashboardWebTestCase {
    func testCanonicalUnreadStateIncludesThreadMissingFromSidebar() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(
            id: "off-sidebar-unread",
            title: "Off-sidebar unread",
            preview: "Not mounted in the sidebar",
            isUnread: true
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
              return [
                document.querySelector('[data-filter-count="unread"]').textContent,
                document.querySelector('[data-thread-list] .dashboard-thread')?.dataset.threadId,
              ];
            })()
            """
        ) as? [String]

        XCTAssertEqual(result, ["1", "off-sidebar-unread"])
    }

    func testUnreadFallbackDetectsSilentReactStateChange() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-one">Thread</button>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(id: "thread-one")
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              row.__reactFiber$test = {
                memoizedProps: { conversationId: 'thread-one', isUnread: true },
                return: null,
              };
              window.__codexDashboard.applySnapshot(\(payload));
              row.__reactFiber$test.memoizedProps = {
                conversationId: 'thread-one',
                isUnread: false,
              };
            })()
            """
        )

        try await Task.sleep(for: .milliseconds(600))
        let unreadCount = try await webView.evaluateJavaScript(
            #"document.querySelector('[data-filter-count="unread"]').textContent"#
        ) as? String

        XCTAssertEqual(unreadCount, "0")
    }

    func testChangedProjectsFilterIncludesEveryThreadFromChangedProjects() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"></aside><main>Conversation surface</main>
            </body></html>
            """,
        )
        let threads = [
            ThreadSummary.fixture(
                id: "changed-project-thread-one",
                title: "First changed project thread",
                preview: "First",
                projectName: "Changed Project",
                projectPath: "/tmp/changed-project",
                sortTimestamp: 3,
                gitStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "changed-project-thread-two",
                title: "Second changed project thread",
                preview: "Second",
                projectName: "Changed Project",
                projectPath: "/tmp/changed-project",
                sortTimestamp: 2
            ),
            ThreadSummary.fixture(
                id: "clean-project-thread",
                title: "Clean project thread",
                preview: "Clean",
                projectName: "Clean Project",
                projectPath: "/tmp/clean-project",
                sortTimestamp: 1
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="changedProjects"]').click();
              return [
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], [
            "changed-project-thread-one",
            "changed-project-thread-two",
        ])
        XCTAssertEqual(values[1] as? String, "1")
    }

    func testRunningSpinnersShowGlobalAndProjectCounts() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let threads = [
            ThreadSummary.fixture(
                id: "project-a-running-one",
                title: "First running thread",
                preview: "Running",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                sortTimestamp: 4,
                runState: .running,
                gitStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-running-two",
                title: "Second running thread",
                preview: "Running",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                sortTimestamp: 3,
                runState: .running,
                gitStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-idle",
                title: "Idle thread",
                preview: "Idle",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                sortTimestamp: 2
            ),
            ThreadSummary.fixture(
                id: "project-b-running",
                title: "Other running thread",
                preview: "Running",
                projectName: "Project B",
                projectPath: "/tmp/project-b",
                sortTimestamp: 1,
                runState: .running,
                gitStatus: .clean
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              return [
                document.querySelector('[data-running-count]').textContent,
                document.querySelector('[data-navigation-running-count]').textContent,
                document.querySelector('[data-navigation-running]').getAttribute('aria-label'),
                [...document.querySelectorAll('.dashboard-project-summary .dashboard-running-spinner')]
                  .map((spinner) => spinner.textContent),
                [...document.querySelectorAll('.dashboard-project-summary .dashboard-running-spinner')]
                  .map((spinner) => spinner.getAttribute('aria-label')),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "3")
        XCTAssertEqual(values[1] as? String, "3")
        XCTAssertEqual(values[2] as? String, "3 running threads")
        XCTAssertEqual(values[3] as? [String], ["2", "1"])
        XCTAssertEqual(values[4] as? [String], ["2 running threads", "1 running thread"])
    }

}
