import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension ThreadDashboardWebTests {
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

    func testUnreadThreadAccessibleNameIncludesUnreadState() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "unread-thread", title: "Needs review", isUnread: true),
        ])

        let accessibleName = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
              return document.querySelector('[data-thread-id="unread-thread"]').getAttribute('aria-label');
            })()
            """
        ) as? String

        XCTAssertEqual(accessibleName, "Unread. Open thread: Needs review")
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
              <script>
                Object.defineProperty(document, 'visibilityState', {
                  configurable: true,
                  value: 'visible',
                });
              </script>
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

        try await Task.sleep(for: .milliseconds(1_700))
        let unreadCount = try await webView.evaluateJavaScript(
            #"document.querySelector('[data-filter-count="unread"]').textContent"#
        ) as? String

        XCTAssertEqual(unreadCount, "0")
    }

}
