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

    func testChangedSnapshotRetainsUnaffectedThreadElements() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let initialPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "changed", title: "Before", recencyEpochMillis: 2),
            .fixture(id: "stable", title: "Stable", recencyEpochMillis: 1),
        ])
        let updatedPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "changed", title: "After", recencyEpochMillis: 2),
            .fixture(id: "stable", title: "Stable", recencyEpochMillis: 1),
        ])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(initialPayload)).threads);
              window.__codexDashboard.open();
              window.__stableThreadElement = document.querySelector('[data-thread-id="stable"]');
              window.__changedThreadElement = document.querySelector('[data-thread-id="changed"]');
              window.__codexDashboard.applyThreads((\(updatedPayload)).threads);
            })()
            """
        )

        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-thread-id=\"changed\"] .dashboard-thread-heading').textContent === 'After'",
            in: webView
        )
        let result = try await webView.evaluateJavaScript(
            """
            [
              window.__stableThreadElement === document.querySelector('[data-thread-id="stable"]'),
              window.__changedThreadElement !== document.querySelector('[data-thread-id="changed"]'),
              document.querySelector('[data-thread-id="changed"] .dashboard-thread-heading').textContent,
            ]
            """
        ) as? [AnyHashable]

        XCTAssertEqual(result, [true, true, "After"])
    }

    func testOpenDashboardCoalescesSnapshotBurstToLatestTaskList() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let now = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let initial = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "initial", title: "Initial task", recencyEpochMillis: now),
        ])
        let latest = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "latest", title: "Latest task", recencyEpochMillis: now),
        ])

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.open();
              const list = document.querySelector('[data-thread-list]');
              window.__taskListRenderCount = 0;
              new MutationObserver(() => { window.__taskListRenderCount += 1; })
                .observe(list, { childList: true });
              window.__codexDashboard.applyThreads((\(initial)).threads);
              window.__codexDashboard.applyThreads((\(latest)).threads);
            })()
            """
        )

        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-thread-id=\"latest\"]') !== null",
            in: webView
        )
        let renderCount = try await webView.evaluateJavaScript(
            "window.__taskListRenderCount"
        ) as? Int
        XCTAssertEqual(renderCount, 1)
    }

    func testClosedDashboardDefersThreadDOMUntilOpened() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "deferred-thread", recencyEpochMillis: now, isUnread: true, runState: .running),
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
              document.querySelector('[data-filter="recent"]').click();
              const saved = JSON.parse(localStorage.getItem('codex-dashboard.task-preferences'));
              const removedLegacy = localStorage.getItem('codex-dashboard.thread-preferences') === null;
              return JSON.stringify([restored, saved.filterMode, Object.hasOwn(saved, 'viewMode'), saved.collapsedProjectPaths[0], saved.hiddenChangeIndicatorPaths[0], document.querySelector('[data-view]') === null, removedLegacy]);
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
        XCTAssertEqual(values[1] as? String, "recent")
        XCTAssertEqual(values[2] as? Bool, false)
        XCTAssertEqual(values[3] as? String, "/tmp/project")
        XCTAssertEqual(values[4] as? String, "/tmp/ignored-project")
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertEqual(values[6] as? Bool, true)
    }

    func testCurrentPreferencesMigrateMutedPathsWithoutKeepingOldField() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: """
            <!doctype html><html><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateJavaScript("""
        window.__codexDashboard.destroy();
        localStorage.setItem('codex-dashboard.task-preferences', JSON.stringify({
          filterMode: 'unread', ignoredProjectPaths: ['/tmp/old'], mutedProjectPaths: ['/tmp/current']
        }));
        """)
        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const stored = JSON.parse(localStorage.getItem('codex-dashboard.task-preferences'));
          return [stored.filterMode, stored.hiddenChangeIndicatorPaths[0], Object.hasOwn(stored, 'ignoredProjectPaths'), Object.hasOwn(stored, 'mutedProjectPaths')];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["unread", "/tmp/current", false, false])
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
            recencyEpochMillis: Int64(Date().timeIntervalSince1970 * 1_000),
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
        XCTAssertEqual(values[0] as? [String], ["BUTTON", "button", "Open task: Keyboard target"])
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

    func testUsageLimitedThreadShowsPersistentForcedHaltMarker() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "usage-halted",
                title: "Interrupted work",
                isUnread: false,
                latestLifecycleEvent: ThreadLifecycleEvent(kind: .forcedHalt, timestamp: .now)
            ),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const row = document.querySelector('[data-thread-id="usage-halted"]');
              const marker = row.querySelector('.dashboard-forced-halt-status');
              return [
                marker?.textContent.trim(),
                marker?.getAttribute('aria-label'),
                Boolean(row.querySelector('.dashboard-open-affordance')),
                Boolean(row.querySelector('.dashboard-completed-status')),
              ];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(
            try XCTUnwrap(result) as? [AnyHashable],
            ["Interrupted", "Interrupted because the usage limit was reached", false, false]
        )
    }

    func testUsageLimitedThreadShowsInterruptedMarkerInNativeSidebar() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><body>
              <aside role="navigation">
                <button data-app-action-sidebar-thread-id="local:usage-halted">
                  <span data-row-content>
                    <span><span data-thread-title-trigger><span data-thread-title>Interrupted work</span></span></span>
                    <span data-status-rail></span>
                  </span>
                </button>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let haltedPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "usage-halted",
                latestLifecycleEvent: ThreadLifecycleEvent(kind: .forcedHalt, timestamp: .now)
            ),
        ])
        let runningPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "usage-halted",
                runState: .running,
                latestLifecycleEvent: ThreadLifecycleEvent(kind: .started, timestamp: .now)
            ),
        ])

        let initial = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(haltedPayload)).threads);
              const marker = document.querySelector('[data-codex-sidebar-interrupted]');
              return [
                Boolean(marker?.parentElement?.querySelector('[data-thread-title-trigger]')),
                marker?.nextElementSibling?.matches('[data-thread-title-trigger]') === true,
                marker?.closest('[data-thread-title-trigger]') === null,
                marker?.closest('[data-status-rail]') === null,
                marker?.textContent,
                marker?.getAttribute('aria-label'),
              ];
            })()
            """
        ) as? [Any]
        XCTAssertEqual(
            initial as? [AnyHashable],
            [true, true, true, true, "Interrupted", "Interrupted because the usage limit was reached"]
        )

        _ = try await webView.evaluateJavaScript(
            """
            document.querySelector('[data-app-action-sidebar-thread-id]').outerHTML =
              '<button data-app-action-sidebar-thread-id="local:usage-halted">'
                + '<span data-row-content>'
                + '<span><span data-thread-title-trigger><span data-thread-title>Interrupted work</span></span></span>'
                + '<span data-status-rail></span>'
                + '</span>'
                + '</button>';
            true;
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(document.querySelector('[data-codex-sidebar-interrupted]'))",
            in: webView
        )

        let removedAfterRestart = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(runningPayload)).threads);
              return document.querySelector('[data-codex-sidebar-interrupted]') === null;
            })()
            """
        ) as? Bool
        XCTAssertEqual(removedAfterRestart, true)
    }

    func testCompletedTickExpiresOneMinuteAfterThreadIsRead() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let unreadPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "completed",
                title: "Finished work",
                recencyEpochMillis: Int64(Date.now.timeIntervalSince1970 * 1_000),
                isUnread: true,
                latestLifecycleEvent: ThreadLifecycleEvent(kind: .completed, timestamp: .now)
            ),
        ])

        let initialResult = try await webView.evaluateJavaScript(
            """
            (() => {
              const completed = (\(unreadPayload)).threads[0];
              window.__codexDashboard.applyThreads([completed]);
              window.__codexDashboard.open();
              const row = () => document.querySelector('[data-thread-id="completed"]');
              return Boolean(row().querySelector('.dashboard-completed-status'));
            })()
            """
        ) as? Bool
        XCTAssertEqual(initialResult, true)

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const completed = (\(unreadPayload)).threads[0];
              window.__codexDashboard.applyThreads([{ ...completed, isUnread: false }]);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(document.querySelector('[data-thread-id=\"completed\"] .dashboard-completed-status'))",
            in: webView
        )
        let afterReadResult = try await webView.evaluateJavaScript(
            """
            Boolean(document.querySelector('[data-thread-id="completed"] .dashboard-completed-status'))
            """
        ) as? Bool
        XCTAssertEqual(afterReadResult, true)

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const completed = (\(unreadPayload)).threads[0];
              window.__codexDashboard.testRealDateNow = Date.now;
              Object.defineProperty(Date, 'now', {
                configurable: true,
                value: () => window.__codexDashboard.testRealDateNow() + 60_001,
              });
              window.__codexDashboard.applyThreads([{ ...completed, isUnread: false }]);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(document.querySelector('[data-thread-id=\"completed\"] .dashboard-open-affordance'))",
            in: webView
        )
        let expiryResult = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-thread-id="completed"]');
              const result = [
                Boolean(row.querySelector('.dashboard-completed-status')),
                Boolean(row.querySelector('.dashboard-open-affordance')),
              ];
              Object.defineProperty(Date, 'now', {
                configurable: true,
                value: window.__codexDashboard.testRealDateNow,
              });
              delete window.__codexDashboard.testRealDateNow;
              return result;
            })()
            """
        ) as? [Bool]

        XCTAssertEqual(expiryResult, [false, true])
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
