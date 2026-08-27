import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TaskDashboardWebTests: SerializedDashboardWebTestCase {
    func testNativeSidebarProjectsExposeExpandedAndCollapsedChevrons() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row aria-expanded="true">Expanded project</div>
                <div data-app-action-sidebar-project-row aria-expanded="false">Collapsed project</div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const rows = [...document.querySelectorAll('[data-app-action-sidebar-project-row]')];
              return rows.map((row) => {
                const style = getComputedStyle(row, '::before');
                return [style.content, style.transform, style.width, style.height];
              });
            })()
            """
        ) as? [[String]]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0][0], #""""#)
        XCTAssertEqual(values[1][0], #""""#)
        XCTAssertNotEqual(values[0][1], values[1][1])
        XCTAssertEqual(values[0][2], "6px")
        XCTAssertEqual(values[0][3], "6px")
    }

    func testUnchangedSnapshotRetainsRenderedThreadElements() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [.fixture(id: "stable")])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              window.__stableThreadElement = document.querySelector('[data-thread-id="stable"]');
              window.__codexDashboard.applyThreads((\(payload)).threads);
            })()
            """
        )

        try await Task.sleep(for: .milliseconds(50))
        let retained = try await webView.evaluateJavaScript(
            "window.__stableThreadElement === document.querySelector('[data-thread-id=\"stable\"]')"
        ) as? Bool
        XCTAssertEqual(retained, true)
    }

    func testClosedDashboardDefersThreadDOMUntilOpened() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "deferred-thread", isUnread: true, runState: .running),
        ])

        let closedState = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              return [
                document.querySelectorAll('[data-thread-list] .dashboard-thread').length,
                document.querySelector('[data-navigation-count]').textContent,
              ];
            })()
            """
        ) as? [Any]
        let closedValues = try XCTUnwrap(closedState)
        XCTAssertEqual(closedValues[0] as? Int, 0)
        XCTAssertEqual(closedValues[1] as? String, "1")

        let openedThreadID = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.open();
              return document.querySelector('[data-thread-list] .dashboard-thread')?.dataset.threadId;
            })()
            """
        ) as? String
        XCTAssertEqual(openedThreadID, "deferred-thread")
    }

    func testRestoresAndSavesDashboardPreferencesWithoutViewMode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-preferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let htmlURL = directory.appendingPathComponent("index.html")
        try Data(
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button>New chat</button></aside><main>Conversation</main>
            </body></html>
            """.utf8
        ).write(to: htmlURL)
        let webView = DashboardWebTestHarness.makeWebView()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: directory)
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let preferencesStored = try await webView.evaluateJavaScript(
            "try { localStorage.setItem('codex-dashboard.thread-preferences', JSON.stringify({ filterMode: 'unread', viewMode: 'recent', collapsedProjects: ['/tmp/project'], ignoredProjectPaths: ['/tmp/ignored-project'] })); true } catch (_) { false }"
        ) as? Bool
        XCTAssertEqual(preferencesStored, true)
        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            ThreadSummary.fixture(id: "one", isUnread: true),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              try {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const restored = document.querySelector('[data-filter="unread"]').classList.contains('is-active');
              document.querySelector('[data-filter="running"]').click();
              const saved = JSON.parse(localStorage.getItem('codex-dashboard.task-preferences'));
              const removedLegacy = localStorage.getItem('codex-dashboard.thread-preferences') === null;
              return JSON.stringify([restored, saved.filterMode, Object.hasOwn(saved, 'viewMode'), saved.collapsedProjects[0], saved.ignoredProjectPaths[0], document.querySelector('[data-view]') === null, removedLegacy]);
              } catch (error) {
                return JSON.stringify({ error: String(error), stack: error?.stack || '' });
              }
            })()
            """
        ) as? String
        let json = try XCTUnwrap(result)
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any]
        )
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "running")
        XCTAssertEqual(values[2] as? Bool, false)
        XCTAssertEqual(values[3] as? String, "/tmp/project")
        XCTAssertEqual(values[4] as? String, "/tmp/ignored-project")
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertEqual(values[6] as? Bool, true)
    }

    func testNavigationShowsUncommittedChangesIndicatorForChangedProjects() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside><main>Conversation surface</main>
            </body></html>
            """,
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(projectPath: "/tmp/dirty", workingTreeStatus: .hasChanges),
            .fixture(id: "clean", projectPath: "/tmp/clean", workingTreeStatus: .clean),
        ])

        let status = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const indicator = document.querySelector('[data-navigation-changes]');
              return [indicator.hidden, indicator.getAttribute('title')];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(status)
        XCTAssertEqual(values[0] as? Bool, false)
        XCTAssertEqual(values[1] as? String, "1 project has uncommitted changes: dirty")
    }

    func testThreadRowUsesNativeButtonAndOpensFromActivation() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-one">Thread</button>
              </aside>
              <main>Conversation surface</main>
              <script>
                document.documentElement.dataset.openCount = '0';
                document.querySelector('[data-app-action-sidebar-thread-id]').addEventListener('click', () => {
                  document.documentElement.dataset.openCount = String(
                    Number(document.documentElement.dataset.openCount) + 1
                  );
                });
              </script>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(
            id: "thread-one",
            title: "Keyboard target",
            runState: .running
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const row = document.querySelector('[data-thread-list] .dashboard-thread');
              const contract = [row.tagName, row.type, row.getAttribute('aria-label')];
              row.click();
              window.__codexDashboard.open();
              document.querySelector('[data-thread-list] .dashboard-thread').click();
              return [contract, document.documentElement.dataset.openCount];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["BUTTON", "button", "Open thread: Keyboard target"])
        XCTAssertEqual(values[1] as? String, "2")
    }

    func testCompletedThreadShowsTickInsteadOfOpenArrow() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "completed",
                title: "Finished work",
                isUnread: true,
                latestLifecycleEvent: ThreadLifecycleEvent(kind: .completed, timestamp: .now)
            ),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
              const row = document.querySelector('[data-thread-id="completed"]');
              return [
                Boolean(row.querySelector('.dashboard-completed-status')),
                Boolean(row.querySelector('.dashboard-open-affordance')),
                row.querySelector('.dashboard-completed-status')?.getAttribute('aria-label'),
              ];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], [true, false, "Completed"])
    }

    func testCompletionRouteDoesNotReplaceOpenDashboard() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let expression = try XCTUnwrap(RendererScript.openThread("completed-thread"))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.documentElement.dataset.routeCount = '0';
              window.addEventListener('message', (event) => {
                if (event.data?.type === 'navigate-to-route') {
                  document.documentElement.dataset.routeCount = String(
                    Number(document.documentElement.dataset.routeCount) + 1
                  );
                }
              });
              window.__codexDashboard.open();
              \(expression);
              return [
                document.documentElement.dataset.routeCount,
                window.__codexDashboard.isOpen(),
              ];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], ["0", true])
    }

}
