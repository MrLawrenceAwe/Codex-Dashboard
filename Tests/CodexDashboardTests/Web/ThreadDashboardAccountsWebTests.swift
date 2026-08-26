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

    func testAccountStatusAndCommitNoticesRenderIndependently() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let snapshot = DashboardSnapshot(
            threads: [],
            accountStatusMessage: "Wait for active tasks to finish before switching accounts."
        )
        let data = try JSONEncoder().encode(snapshot)
        let payload = try XCTUnwrap(String(data: data, encoding: .utf8))

        _ = try await webView.evaluateJavaScript(
            "window.__codexDashboard.open(); window.__codexDashboard.applySnapshot(\(payload));"
        )
        try await Task.sleep(for: .milliseconds(100))
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.querySelector('[data-account-notice]').hidden,
              document.querySelector('[data-account-notice]').textContent,
              document.querySelector('[data-commit-notice]').hidden,
              document.querySelector('[data-commit-notice]').textContent,
            ]
            """
        ) as? [Any]

        XCTAssertEqual(
            try XCTUnwrap(state) as? [AnyHashable],
            [false, "Wait for active tasks to finish before switching accounts.", true, ""]
        )
    }

    func testAccountSelectorPublishesSwitchAction() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let personalID = UUID()
        let workID = UUID()
        let snapshot = DashboardSnapshot(
            threads: [],
            accounts: [
                SavedAccountOption(
                    id: personalID.uuidString, name: "Personal", isActive: true
                ),
                SavedAccountOption(id: workID.uuidString, name: "Work", isActive: false),
            ],
            activeAccountID: personalID.uuidString,
            accountStatusMessage: "Ready"
        )
        let data = try JSONEncoder().encode(snapshot)
        let payload = try XCTUnwrap(String(data: data, encoding: .utf8))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const select = document.querySelector('[data-account-select]');
              const initial = [select.options.length, select.value, select.options[1].textContent.trim()];
              select.value = \(String(reflecting: workID.uuidString));
              select.dispatchEvent(new Event('change', { bubbles: true }));
              return [initial, JSON.parse(window.__codexDashboard.consumeAccountAction())];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [AnyHashable], [2, personalID.uuidString, "Work"])
        let action = try XCTUnwrap(values[1] as? [String: String])
        XCTAssertEqual(action["type"], "switch")
        XCTAssertEqual(action["accountID"], workID.uuidString)
    }

    func testSavingAccountDoesNotPromptForAUserDefinedName() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              let promptCount = 0;
              window.prompt = () => { promptCount += 1; return 'Custom'; };
              document.querySelector('[data-account-save]').click();
              return [
                promptCount,
                document.querySelector('[data-account-save]').textContent,
                JSON.parse(window.__codexDashboard.consumeAccountAction()),
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 0)
        XCTAssertEqual(values[1] as? String, "Save account")
        XCTAssertEqual(values[2] as? [String: String], ["type": "save"])
    }

    func testAccountSelectorShowsCurrentAccountWhenNoSavedAccountIsActive() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let savedID = UUID()
        let snapshot = DashboardSnapshot(
            threads: [],
            accounts: [SavedAccountOption(id: savedID.uuidString, name: "Saved", isActive: false)],
            activeAccountID: nil,
            accountStatusMessage: nil
        )
        let data = try JSONEncoder().encode(snapshot)
        let payload = try XCTUnwrap(String(data: data, encoding: .utf8))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const select = document.querySelector('[data-account-select]');
              return [select.options.length, select.value, select.options[0].textContent.trim()];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], [2, "", "Current account"])
    }

}
