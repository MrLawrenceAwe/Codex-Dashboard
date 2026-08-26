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
              typeof window.__codexDashboard.consumeAccountPopoverAction,
            ]
            """
        ) as? [Any]

        XCTAssertEqual(
            try XCTUnwrap(state) as? [AnyHashable],
            [true, true, true, true, true, "function"]
        )
    }

    func testAccountsMountInCodexProfilePopoverAndQueueNativeActions() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <aside role="navigation"><button>New chat</button></aside>
          <main>Conversation surface</main>
          <div role="menu" id="profile-menu">
            <div class="menu-items">
              <div role="menuitem"><span>Usage remaining</span></div>
              <div role="menuitem"><span>Show pet</span></div>
              <div role="menuitem"><span>Settings</span><kbd>⌘,</kbd></div>
              <div role="menuitem"><span>Log out</span></div>
            </div>
          </div>
        </body></html>
        """)

        let state = try await webView.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.applyAccountPopoverSnapshot({
            accounts: [{
              id: '00000000-0000-0000-0000-000000000001',
              name: 'Lawrence',
              isActive: false,
              usageLines: ['5-hour: 88% remaining'],
              isRefreshing: false,
              errorMessage: null,
            }],
            activeAccountID: null,
            statusMessage: null,
            isBusy: false,
          });
          const trigger = document.querySelector('[data-codex-accounts-trigger]');
          trigger.click();
          const panel = document.querySelector('#codex-accounts-panel');
          panel.querySelector('[data-account-action="update"]').click();
          return [
            trigger.textContent.trim(),
            panel.textContent.includes('Lawrence'),
            panel.textContent.includes('5-hour:') && panel.textContent.includes('88% remaining'),
            JSON.parse(window.__codexDashboard.consumeAccountPopoverAction()),
          ];
        })()
        """) as? [Any]

        let values = try XCTUnwrap(state)
        XCTAssertEqual(values[0] as? String, "Accounts›")
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
        let action = try XCTUnwrap(values[3] as? [String: Any])
        XCTAssertEqual(action["kind"] as? String, "updateUsage")
        XCTAssertEqual(action["accountID"] as? String, "00000000-0000-0000-0000-000000000001")
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
