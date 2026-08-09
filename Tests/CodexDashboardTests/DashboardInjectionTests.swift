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
                workspaceName: "Project",
                workspacePath: "/tmp/project",
                recencyTimestamp: 2,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .clean
            ),
            DashboardThread(
                id: "thread-unread",
                title: "Unread thread",
                preview: "Needs attention",
                workspaceName: "Project",
                workspacePath: "/tmp/project",
                recencyTimestamp: 1,
                isPinned: true,
                model: "test-model",
                activity: .running,
                gitWorkingTreeStatus: .hasChanges
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
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
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

    func testUncommittedFilterIncludesEveryThreadFromProjectsWithChanges() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"></aside><main>Conversation surface</main>
            </body></html>
            """,
            baseURL: nil
        )
        try await waitUntilLoaded(webView)

        let injection = try DashboardInjection.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let threads = [
            DashboardThread(
                id: "changed-project-thread-one",
                title: "First changed project thread",
                preview: "First",
                workspaceName: "Changed Project",
                workspacePath: "/tmp/changed-project",
                recencyTimestamp: 3,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .hasChanges
            ),
            DashboardThread(
                id: "changed-project-thread-two",
                title: "Second changed project thread",
                preview: "Second",
                workspaceName: "Changed Project",
                workspacePath: "/tmp/changed-project",
                recencyTimestamp: 2,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .clean
            ),
            DashboardThread(
                id: "clean-project-thread",
                title: "Clean project thread",
                preview: "Clean",
                workspaceName: "Clean Project",
                workspacePath: "/tmp/clean-project",
                recencyTimestamp: 1,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .clean
            ),
        ]
        let payloadData = try JSONEncoder().encode(DashboardPayload(threads: threads))
        let payload = try XCTUnwrap(String(data: payloadData, encoding: .utf8))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="uncommitted"]').click();
              return [
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter-count="uncommitted"]').textContent,
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

    func testSavedPromptsCanBeCreatedAndInsertedIntoComposer() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>
                <div data-composer-overlay-floating-ui="true" aria-label="Add">
                  <button role="menuitem" data-list-navigation-item="true" class="opacity-75 bg-token-list-hover-background opacity-100"><span>Record a skill</span></button>
                </div>
                <textarea placeholder="Do anything"></textarea>
                <div contenteditable="true" role="textbox"></div>
              </main>
            </body></html>
            """,
            baseURL: nil
        )
        try await waitUntilLoaded(webView)

        let injection = try DashboardInjection.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const promptMenuItem = document.querySelector('[data-codex-prompt-menu-item]');
              promptMenuItem.dispatchEvent(new PointerEvent('pointerenter'));
              const promptTookHighlight = promptMenuItem.classList.contains('opacity-100')
                && promptMenuItem.classList.contains('bg-token-list-hover-background')
                && !document.querySelector('[data-list-navigation-item]:not([data-codex-prompt-menu-item])').classList.contains('opacity-100');
              promptMenuItem.dispatchEvent(new PointerEvent('pointerdown', {
                bubbles: true,
                cancelable: true,
              }));
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Review code';
              document.querySelector('[name="content"]').value = 'Review this code for correctness issues.';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const savedPromptName = document.querySelector('[data-prompt-use] strong').textContent;
              document.querySelector('[data-prompt-use]').click();
              const textareaValue = document.querySelector('textarea[placeholder="Do anything"]').value;
              document.querySelector('textarea[placeholder="Do anything"]').remove();
              promptMenuItem.click();
              document.querySelector('[data-prompt-use]').click();
              return [
                promptMenuItem.textContent.trim(),
                savedPromptName,
                textareaValue,
                !document.getElementById('codex-dashboard-prompt-dialog'),
                promptMenuItem.parentElement.getAttribute('data-composer-overlay-floating-ui'),
                document.querySelector('[contenteditable="true"]').textContent,
                promptTookHighlight,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Prompts")
        XCTAssertEqual(values[1] as? String, "Review code")
        XCTAssertEqual(values[2] as? String, "Review this code for correctness issues.")
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "true")
        XCTAssertEqual(values[5] as? String, "Review this code for correctness issues.")
        XCTAssertEqual(values[6] as? Bool, true)

        let removedOnDestroy = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.destroy();
              return !document.querySelector('[data-codex-prompt-menu-item]');
            })()
            """
        ) as? Bool
        XCTAssertEqual(removedOnDestroy, true)
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
