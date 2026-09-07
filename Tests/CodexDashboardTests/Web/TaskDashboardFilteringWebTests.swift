import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension TaskDashboardWebTests {
    func testCompleteCatalogUsesClientPaging() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let threads = (0..<65).map { index in
            ThreadSummary.fixture(
                id: "thread-\(index)",
                title: "Thread \(index)",
                recencyEpochMillis: Int64(65 - index),
                runState: .running
            )
        }
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)
        let initial = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="running"]').click();
              const initialCount = document.querySelectorAll('[data-thread-list] .dashboard-thread').length;
              const loadMoreVisible = !document.querySelector('[data-load-more]').hidden;
              document.querySelector('[data-load-more]').click();
              const expandedCount = document.querySelectorAll('[data-thread-list] .dashboard-thread').length;
              return [
                initialCount,
                loadMoreVisible,
                expandedCount,
                document.querySelector('[data-thread-list] .dashboard-thread:last-child')?.dataset.threadId,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(initial)
        XCTAssertEqual(values[0] as? Int, 10)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Int, 20)
        XCTAssertEqual(values[3] as? String, "thread-19")
    }

    func testRunningFilterShowsOnlyRunningThreads() async throws {
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
                recencyEpochMillis: 4,
                runState: .running,
                workingTreeStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-running-two",
                title: "Second running thread",
                preview: "Running",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                recencyEpochMillis: 3,
                runState: .running,
                workingTreeStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-idle",
                title: "Idle thread",
                preview: "Idle",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                recencyEpochMillis: 2
            ),
            ThreadSummary.fixture(
                id: "project-b-running",
                title: "Other running thread",
                preview: "Running",
                projectName: "Project B",
                projectPath: "/tmp/project-b",
                recencyEpochMillis: 1,
                runState: .running,
                workingTreeStatus: .clean
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="running"]').click();
              return [
                document.querySelector('[data-navigation-running-count]').textContent,
                document.querySelector('[data-navigation-running]').getAttribute('aria-label'),
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter="running"]').classList.contains('is-active'),
                document.querySelector('[data-filter="running"]').textContent.trim(),
                document.querySelector('[data-filter-count="running"]').textContent,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "3")
        XCTAssertEqual(values[1] as? String, "3 running tasks")
        XCTAssertEqual(
            values[2] as? [String],
            ["project-a-running-one", "project-a-running-two", "project-b-running"]
        )
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "Running 3")
        XCTAssertEqual(values[5] as? String, "3")
    }

    func testRecentFilterIsDefaultAndKeepsTasksInStrictRecencyOrder() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "yesterday", title: "Yesterday's task", projectPath: "/tmp/a", recencyEpochMillis: now - 86_400_000),
            .fixture(id: "oldest", title: "Earlier task", projectPath: "/tmp/a", recencyEpochMillis: now - 3_000),
            .fixture(id: "newest", title: "Latest task", projectPath: "/tmp/a", recencyEpochMillis: now - 1_000),
            .fixture(id: "middle", title: "Middle task", projectPath: "/tmp/b", recencyEpochMillis: now - 2_000),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const initialIDs = [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                .map((thread) => thread.dataset.threadId);
              return [
                document.querySelector('[data-filter="recent"]').classList.contains('is-active'),
                document.querySelector('[data-filter="all"]') === null,
                initialIDs,
                document.querySelector('[data-filter-count="recent"]') === null,
                document.querySelector('[data-thread-list] .dashboard-project-group') === null,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? [String], ["newest", "middle", "oldest", "yesterday"])
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? Bool, true)
    }

}
