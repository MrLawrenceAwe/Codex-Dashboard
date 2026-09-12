import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension TaskDashboardWebTests {
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
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.querySelector('[data-account-controls]') === null,
              document.querySelector('[data-account-select]') === null,
              document.querySelector('[data-account-save]') === null,
              document.querySelector('[data-account-add]') === null,
              document.querySelector('[data-account-notice]') === null,
              typeof window.__codexDashboard.waitForAccountPopoverAction,
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
              <div role="menuitem"><span>Settings</span><kbd>⌘,</kbd></div>
              <div role="menuitem"><span>Log out</span></div>
            </div>
          </div>
        </body></html>
        """)

        let state = try await webView.evaluateJavaScript("""
        (() => {
          const snapshot = {
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
          };
          window.__codexDashboard.applyAccountPopoverSnapshot(snapshot);
          const trigger = document.querySelector('[data-codex-accounts-trigger]');
          trigger.click();
          const panel = document.querySelector('#codex-accounts-panel');
          const initialCard = panel.querySelector('.codex-accounts-card');
          window.__codexDashboard.applyAccountPopoverSnapshot(snapshot);
          const retainedUnchangedCard = initialCard === panel.querySelector('.codex-accounts-card');
          return [
            trigger.textContent.trim(),
            panel.textContent.includes('Lawrence'),
            panel.textContent.includes('5-hour:') && panel.textContent.includes('88% remaining'),
            retainedUnchangedCard,
          ];
        })()
        """) as? [Any]

        let values = try XCTUnwrap(state)
        XCTAssertEqual(values[0] as? String, "Accounts›")
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
        let pendingAction = Task { @MainActor in
            try await webView.callAsyncJavaScript(
                "return await window.__codexDashboard.waitForAccountPopoverAction();",
                contentWorld: .page
            ) as? String
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await webView.evaluateJavaScript(
            "document.querySelector('[data-account-action=\"update\"]').click()"
        )
        let serializedAction = try await pendingAction.value
        let actionData = try XCTUnwrap(serializedAction?.data(using: String.Encoding.utf8))
        let action = try XCTUnwrap(
            JSONSerialization.jsonObject(with: actionData) as? [String: Any]
        )
        XCTAssertEqual(action["kind"] as? String, "updateUsage")
        XCTAssertEqual(action["accountID"] as? String, "00000000-0000-0000-0000-000000000001")
    }

    func testClosedProfileMenuExposesPersistentCompatibilityContract() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <button aria-label="Open profile menu" aria-haspopup="menu">Lawrence</button>
        </body></html>
        """)
        let contractSource = try InjectionBundle.loadRendererContractSource()

        let compatible = try await webView.evaluateJavaScript("""
        (() => {
          \(contractSource)
          return Boolean(codexUIContracts.profileMenuTrigger());
        })()
        """) as? Bool

        XCTAssertEqual(compatible, true)
    }

    func testAccountsPanelStaysWithinANarrowWindow() async throws {
        let webView = DashboardWebTestHarness.makeWebView()
        webView.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        webView.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <div role="menu">
            <div role="menuitem"><span>Show pet</span></div>
            <div role="menuitem"><span>Settings</span></div>
            <div role="menuitem"><span>Log out</span></div>
          </div>
        </body></html>
        """, baseURL: nil)
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)

        let values = try await webView.evaluateJavaScript("""
        (() => {
          document.querySelector('[data-codex-accounts-trigger]').click();
          const rect = document.querySelector('#codex-accounts-panel').getBoundingClientRect();
          return [rect.left, rect.right, innerWidth];
        })()
        """) as? [Double]

        let bounds = try XCTUnwrap(values)
        XCTAssertGreaterThanOrEqual(bounds[0], 12)
        XCTAssertLessThanOrEqual(bounds[1], bounds[2] - 12)
    }

    func testRefreshingUsageKeepsAccountPanelOpenWhenCodexClosesProfileMenu() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <div role="menu" id="profile-menu">
            <div role="menuitem"><span>Show pet</span></div>
            <div role="menuitem"><span>Settings</span></div>
            <div role="menuitem"><span>Log out</span></div>
          </div>
        </body></html>
        """)

        _ = try await webView.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.applyAccountPopoverSnapshot({
            accounts: [{
              id: '00000000-0000-0000-0000-000000000001', name: 'Lawrence',
              isActive: false, usageLines: [], isRefreshing: false, errorMessage: null,
            }],
            activeAccountID: null, statusMessage: null, isBusy: false,
          });
          document.querySelector('[data-codex-accounts-trigger]').click();
          document.querySelector('[data-account-action="update"]').click();
          document.querySelector('#profile-menu').remove();
        })()
        """)
        try await Task.sleep(for: .milliseconds(50))
        let panelIsOpen = try await webView.evaluateJavaScript(
            "document.querySelector('#codex-accounts-panel') !== null"
        ) as? Bool

        XCTAssertEqual(panelIsOpen, true)
    }

    func testCommitNoticeRemainsAvailable() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
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
