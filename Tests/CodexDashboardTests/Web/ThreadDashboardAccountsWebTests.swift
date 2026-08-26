import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension ThreadDashboardWebTests {
    func testDashboardInsetAccountsForScaledCodexShell() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"><style>
              body { margin: 0; }
              .shell { display: flex; width: 1000px; zoom: .6; }
              aside { width: 275px; flex: 0 0 275px; }
              main { flex: 1; }
            </style></head><body>
              <div class="shell">
                <aside class="app-shell-left-panel" role="navigation"></aside>
                <main>Conversation surface</main>
              </div>
            </body></html>
            """
        )

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const sidebarRight = document.querySelector('aside').getBoundingClientRect().right;
              const pageLeft = document.querySelector('#codex-dashboard-page').getBoundingClientRect().left;
              const inset = getComputedStyle(document.documentElement)
                .getPropertyValue('--codex-dashboard-content-left');
              return [sidebarRight, pageLeft, inset];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(values[0] as? Double), 165, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(values[1] as? Double), 165, accuracy: 0.5)
        XCTAssertEqual(values[2] as? String, "275px")
    }

    func testDashboardDoesNotRenderAccountControlsOrAccountStatusNotice() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.querySelector('[data-account-controls]') === null,
              document.querySelector('[data-account-select]') === null,
              document.querySelector('[data-account-save]') === null,
              document.querySelector('[data-account-add]') === null,
              document.querySelector('[data-account-notice]') === null,
              typeof window.__codexDashboard.consumeAccountAction,
            ]
            """
        ) as? [Any]

        XCTAssertEqual(
            try XCTUnwrap(state) as? [AnyHashable],
            [true, true, true, true, true, "undefined"]
        )
    }

    func testCommitNoticeRemainsAvailable() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.open();
              const notice = document.querySelector('[data-commit-notice]');
              notice.textContent = 'Could not commit.';
              notice.hidden = false;
              return [notice.hidden, notice.textContent];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], [false, "Could not commit."])
    }

}
