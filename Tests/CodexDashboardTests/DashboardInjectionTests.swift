import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardInjectionTests: XCTestCase {
    func testDashboardMountsFiltersNavigatesAndDestroys() async throws {
        let webView = WKWebView()
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
        try await waitUntilLoaded(webView)

        let injection = try DashboardInjection.load()
        let mounted = try await webView.evaluateJavaScript(injection.mountExpression) as? Bool
        XCTAssertEqual(mounted, true)
        let healthy = try await webView.evaluateJavaScript(injection.healthCheckExpression) as? Bool
        XCTAssertEqual(healthy, true)

        let threads = [
            DashboardThread(
                id: "thread-read",
                title: "Read thread",
                preview: "Already read",
                workspace: "Project",
                workspacePath: "/tmp/project",
                updatedAtUnixSeconds: 2,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitStatus: .clean
            ),
            DashboardThread(
                id: "thread-unread",
                title: "Unread thread",
                preview: "Needs attention",
                workspace: "Project",
                workspacePath: "/tmp/project",
                updatedAtUnixSeconds: 1,
                isPinned: true,
                model: "test-model",
                activity: .running,
                gitStatus: .modified
            ),
        ]
        let payloadData = try JSONEncoder().encode(DashboardPayload(threads: threads))
        let payload = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const unreadRow = document.querySelector('[data-app-action-sidebar-thread-id="local:thread-unread"]');
              unreadRow.__reactFiber$test = {
                memoizedProps: { conversationId: 'thread-unread', isUnread: true },
                return: null,
              };
              unreadRow.addEventListener('click', () => { window.__openedThreadID = 'thread-unread'; });
              window.__codexDashboard.update(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-read-filter="unread"]').click();
              const visibleThreads = document.querySelectorAll('[data-thread-list] .dashboard-thread');
              visibleThreads[0].querySelector('[data-open-thread]').click();
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

        let destroyed = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.destroy();
              return typeof window.__codexDashboard === 'undefined'
                && !document.getElementById('codex-dashboard-page')
                && !document.getElementById('codex-dashboard-navigation');
            })()
            """
        ) as? Bool
        XCTAssertEqual(destroyed, true)
    }

    private func waitUntilLoaded(_ webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while webView.isLoading {
            guard ContinuousClock.now < deadline else {
                throw DashboardError.invalidDevToolsResponse
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
