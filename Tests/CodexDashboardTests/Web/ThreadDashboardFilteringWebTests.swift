import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension ThreadDashboardWebTests {
    func testCompleteCatalogUsesClientPagingAndSearchesBeyondFirstPage() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let threads = (0..<65).map { index in
            ThreadSummary.fixture(
                id: "thread-\(index)",
                title: index == 64 ? "Needle outside first page" : "Thread \(index)",
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
              const initialCount = document.querySelectorAll('[data-thread-list] .dashboard-thread').length;
              const loadMoreVisible = !document.querySelector('[data-load-more]').hidden;
              document.querySelector('[data-load-more]').click();
              const expandedCount = document.querySelectorAll('[data-thread-list] .dashboard-thread').length;
              const search = document.querySelector('[data-dashboard-search]');
              search.value = 'Needle outside';
              search.dispatchEvent(new Event('input', { bubbles: true }));
              document.querySelector('[data-filter="running"]').click();
              return [
                initialCount,
                loadMoreVisible,
                expandedCount,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(initial)
        XCTAssertEqual(values[0] as? Int, 60)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Int, 65)
        let matchingID = try await webView.evaluateJavaScript(
            "document.querySelector('[data-thread-list] .dashboard-thread')?.dataset.threadId"
        ) as? String
        XCTAssertEqual(matchingID, "thread-64")
    }

    func testSearchResultsRemainPaged() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let threads = (0..<125).map { index in
            ThreadSummary.fixture(
                id: "matching-\(index)",
                title: "Matching thread \(index)",
                runState: .running
            )
        }
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const search = document.querySelector('[data-dashboard-search]');
              search.value = 'Matching';
              search.dispatchEvent(new Event('input', { bubbles: true }));
              return true;
            })()
            """
        )
        let result = try await webView.evaluateJavaScript(
            """
            [
              document.querySelectorAll('[data-thread-list] .dashboard-thread').length,
              !document.querySelector('[data-load-more]').hidden,
            ]
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 60)
        XCTAssertEqual(values[1] as? Bool, true)
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
                document.querySelector('[data-dashboard-summary]').getAttribute('aria-label'),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "3")
        XCTAssertEqual(values[1] as? String, "3 running threads")
        XCTAssertEqual(
            values[2] as? [String],
            ["project-a-running-one", "project-a-running-two", "project-b-running"]
        )
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "Running 3")
        XCTAssertEqual(values[5] as? String, "3")
        XCTAssertEqual(values[6] as? String, "3 running, 0 unread, 0 changed projects")
    }

    func testRunningFilterIsDefaultAndAllFilterIsAbsent() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "running", title: "Active work", runState: .running),
            .fixture(id: "idle", title: "Archived needle", runState: .idle),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const initialIDs = [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                .map((thread) => thread.dataset.threadId);
              const search = document.querySelector('[data-dashboard-search]');
              search.value = 'Archived needle';
              search.dispatchEvent(new Event('input', { bubbles: true }));
              document.querySelector('[data-filter="running"]').click();
              return [
                document.querySelector('[data-filter="running"]').classList.contains('is-active'),
                document.querySelector('[data-filter="all"]') === null,
                initialIDs,
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter-count="running"]').textContent,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? [String], ["running"])
        XCTAssertEqual(values[3] as? [String], [])
        XCTAssertEqual(values[4] as? String, "1")
    }

}
