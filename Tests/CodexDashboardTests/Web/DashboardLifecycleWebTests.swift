import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardLifecycleWebTests: SerializedDashboardWebTestCase {
    func testInjectedNavigationHoverDoesNotReachNativeSidebar() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><body>
          <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
          <main>Conversation surface</main>
        </body></html>
        """)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              let nativeHoverCount = 0;
              document.querySelector('aside').addEventListener('mouseover', () => {
                nativeHoverCount += 1;
              });
              for (const id of ['codex-dashboard-navigation', 'codex-dashboard-todo-navigation']) {
                document.getElementById(id).dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
              }
              return nativeHoverCount;
            })()
            """
        ) as? Int

        XCTAssertEqual(result, 0)
    }

    func testSidebarObserverIgnoresDashboardMutationsAndTracksThreadRowChanges() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <aside class="app-shell-left-panel" role="navigation">
            <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread">Thread</button>
          </aside>
          <main>Conversation surface</main>
        </body></html>
        """)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "thread", isUnread: false),
        ])

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              row.__reactFiber$test = {
                memoizedProps: { conversationId: 'thread', isUnread: false },
                return: null,
              };
              window.__codexDashboard.applyThreads((\(payload)).threads);
              row.__reactFiber$test.memoizedProps.isUnread = true;
              document.getElementById('codex-dashboard-navigation')
                .append(document.createElement('span'));
              return true;
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(100))
        let unreadCountAfterDashboardMutation = try await webView.evaluateJavaScript(
            "document.querySelector('[data-navigation-count]').textContent"
        ) as? String
        XCTAssertEqual(unreadCountAfterDashboardMutation, "0")

        _ = try await webView.evaluateJavaScript(
            """
            document.querySelector('[data-app-action-sidebar-thread-id]')
              .append(document.createElement('span'));
            true;
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-navigation-count]').textContent === '1'",
            in: webView
        )
    }

    func testDashboardLifecycleAndCoreInteractions() async throws {
        let webView = DashboardWebTestHarness.makeWebView()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html>
              <head><meta charset="utf-8"></head>
              <body>
                <div class="mock-app">
                  <aside class="app-shell-left-panel" role="navigation">
                    <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-read">Read thread</button>
                    <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-unread">Unread thread</button>
                  </aside>
                  <main>Conversation surface</main>
                </div>
              </body>
            </html>
            """,
            baseURL: nil
        )
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let injection = try InjectionBundle.load()
        let mounted = try await webView.evaluateJavaScript(injection.mountExpression) as? Bool
        XCTAssertEqual(mounted, true)
        let healthy = try await webView.evaluateJavaScript(injection.healthCheckExpression) as? Bool
        XCTAssertEqual(healthy, true)

        let dashboardStyles = try await webView.evaluateJavaScript(
            """
            (() => {
              const styles = getComputedStyle(document.getElementById('codex-dashboard-page'));
              return [styles.backgroundColor, styles.color, styles.getPropertyValue('--dashboard-bg').trim()];
            })()
            """
        ) as? [String]
        XCTAssertEqual(dashboardStyles, ["rgb(33, 33, 33)", "rgb(236, 236, 236)", "#212121"])

        let themedDashboardStyles = try await webView.evaluateJavaScript(
            """
            (() => {
              const root = document.documentElement.style;
              const readStyles = () => {
                const page = getComputedStyle(document.getElementById('codex-dashboard-page'));
                const navigation = getComputedStyle(document.getElementById('codex-dashboard-navigation'));
                const navigationCopy = getComputedStyle(document.querySelector('.dashboard-nav-copy'));
                return [page.backgroundColor, page.color, navigationCopy.color, navigation.color];
              };
              root.setProperty('--color-background-surface', '#ffffff');
              root.setProperty('--color-text-foreground', '#1a1c1f');
              const light = readStyles();
              root.setProperty('--color-background-surface', '#212121');
              root.setProperty('--color-text-foreground', '#ececec');
              document.getElementById('codex-dashboard-navigation').style.color = '#ececec';
              const dark = readStyles();
              return [light, dark];
            })()
            """
        ) as? [[String]]
        XCTAssertEqual(themedDashboardStyles, [
            ["rgb(255, 255, 255)", "rgb(26, 28, 31)", "rgba(0, 0, 0, 0.847)", "rgba(0, 0, 0, 0.847)"],
            ["rgb(33, 33, 33)", "rgb(236, 236, 236)", "rgb(236, 236, 236)", "rgb(236, 236, 236)"],
        ])

        let threads = [
            ThreadSummary.fixture(
                id: "thread-read",
                title: "Read thread",
                preview: "Already read",
                projectName: "Project",
                projectPath: "/tmp/project",
                recencyEpochMillis: 2
            ),
            ThreadSummary.fixture(
                id: "thread-unread",
                title: "Unread thread",
                preview: "Needs attention",
                projectName: "Project",
                projectPath: "/tmp/project",
                recencyEpochMillis: 1,
                isPinned: true,
                model: "test-model",
                runState: .running,
                workingTreeStatus: .hasChanges
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const unreadRow = document.querySelector('[data-app-action-sidebar-thread-id="local:thread-unread"]');
              unreadRow.__reactFiber$test = {
                memoizedProps: { conversationId: 'thread-unread', isUnread: true },
                return: null,
              };
              unreadRow.addEventListener('click', () => { window.__openedThreadID = 'thread-unread'; });
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
              const visibleThreads = document.querySelectorAll('[data-thread-list] .dashboard-thread');
              visibleThreads[0].click();
              return [
                Boolean(document.getElementById('codex-dashboard-navigation')),
                visibleThreads.length,
                visibleThreads[0].dataset.threadId,
                document.documentElement.classList.contains('codex-dashboard-open'),
                window.__openedThreadID,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Int, 1)
        XCTAssertEqual(values[2] as? String, "thread-unread")
        XCTAssertEqual(values[3] as? Bool, false)
        XCTAssertEqual(values[4] as? String, "thread-unread")

        let closesForHostRouteChanges = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.open();
              window.dispatchEvent(new MessageEvent('message', {
                data: { type: 'navigate-to-route', path: '/local/another-thread' },
              }));
              const closedForMessage = !document.documentElement.classList.contains('codex-dashboard-open');
              window.__codexDashboard.open();
              window.dispatchEvent(new PopStateEvent('popstate'));
              const closedForHistory = !document.documentElement.classList.contains('codex-dashboard-open');
              window.__codexDashboard.open();
              document.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'n', metaKey: true, bubbles: true,
              }));
              const closedForNewChatShortcut = !document.documentElement.classList.contains('codex-dashboard-open');
              return [closedForMessage, closedForHistory, closedForNewChatShortcut];
            })()
            """
        ) as? [Bool]
        XCTAssertEqual(closesForHostRouteChanges, [true, true, true])

        let destroyed = try await webView.evaluateJavaScript(
            """
            (() => {
              let clearedTimerCount = 0;
              const originalClearTimeout = window.clearTimeout;
              window.clearTimeout = (timer) => {
                clearedTimerCount += 1;
                originalClearTimeout(timer);
              };
              window.__codexDashboard.destroy();
              return [
                typeof window.__codexDashboard === 'undefined'
                  && !document.getElementById('codex-dashboard-page')
                  && !document.getElementById('codex-dashboard-navigation'),
                clearedTimerCount,
              ];
            })()
            """
        ) as? [Any]
        XCTAssertEqual(destroyed?[0] as? Bool, true)
        XCTAssertEqual(destroyed?[1] as? Int, 1)
    }

}
