import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class SidebarProjectHighlightWebTests: SerializedDashboardWebTestCase {
    func testSharedColoursPersistByProjectIDSurviveRowReplacementAndCleanUp() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: """
            <html><body><aside><button>New chat</button>
              <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="first"
                data-app-action-sidebar-project-label="Same name" aria-expanded="true" role="button" tabindex="0">
                <span data-marquee-text>Same name</span>
              </div>
              <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="second"
                data-app-action-sidebar-project-label="Same name" aria-expanded="false" role="button" tabindex="0">
                <span data-marquee-text>Same name</span>
              </div>
            </aside><main></main></body></html>
            """,
            baseURL: URL(string: "https://sidebar-colours.codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateJavaScript("""
        window.rowClicks = 0;
        document.querySelector('[data-app-action-sidebar-project-id="first"]')
          .addEventListener('click', () => window.rowClicks++);
        document.querySelector('[data-codex-project-colour]').click();
        document.querySelector('[data-colour="Purple"]').click();
        """)
        let initial = try await webView.evaluateJavaScript("""
        [document.querySelectorAll('[data-codex-project-highlight-name]').length,
         window.rowClicks,
         document.activeElement.hasAttribute('data-codex-project-colour')]
        """) as? [Any]
        XCTAssertEqual(initial?[0] as? Int, 1)
        XCTAssertEqual(initial?[1] as? Int, 0)
        XCTAssertEqual(initial?[2] as? Bool, true)
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-app-action-sidebar-project-id="second"] [data-codex-project-colour]').click();
        document.querySelector('[data-colour="Purple"]').click();
        """)
        let shared = try await webView.evaluateJavaScript(
            "document.querySelectorAll('[data-codex-project-highlight-name]').length"
        ) as? Int
        XCTAssertEqual(shared, 2)
        _ = try await webView.evaluateJavaScript("""
        const row = document.querySelector('[data-app-action-sidebar-project-id="first"]');
        row.innerHTML = '<span data-marquee-text>Renamed project</span>';
        row.setAttribute('data-app-action-sidebar-project-label', 'Renamed project');
        """)
        try await Task.sleep(for: .milliseconds(100))
        let repaired = try await webView.evaluateJavaScript(
            "document.querySelector('[data-codex-project-highlight-name]').textContent"
        ) as? String
        XCTAssertEqual(repaired, "Renamed project")
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.destroy()")
        let cleaned = try await webView.evaluateJavaScript(
            "document.querySelectorAll('[data-codex-project-colour], [data-codex-project-highlight-name], #codex-sidebar-project-colours').length"
        ) as? Int
        XCTAssertEqual(cleaned, 0)
        _ = try await webView.evaluateJavaScript(InjectionBundle.load().mountExpression)
        let restored = try await webView.evaluateJavaScript(
            "document.querySelector('[data-codex-project-highlight-name]').style.getPropertyValue('--codex-project-highlight')"
        ) as? String
        XCTAssertEqual(restored, "#ae87d9")
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-codex-project-colour]').click();
        document.querySelector('[data-colour=""]').click();
        """)
        let cleared = try await webView.evaluateJavaScript(
            "document.querySelectorAll('[data-codex-project-highlight-name]').length"
        ) as? Int
        XCTAssertEqual(cleared, 1)
        let saved = try await webView.evaluateJavaScript(
            "Object.keys(JSON.parse(localStorage.getItem('codex-dashboard.sidebar-project-highlights'))).length"
        ) as? Int
        XCTAssertEqual(saved, 1)
    }

    func testKeyboardOpensPickerAndEscapeDismissesWithoutTogglingProject() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <html><body><aside role="navigation"><button>New chat</button>
          <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="first"
            data-app-action-sidebar-project-label="Project" aria-expanded="false">
            <span data-marquee-text>Project</span>
          </div>
        </aside><main></main></body></html>
        """)
        let opened = try await webView.evaluateJavaScript("""
        (() => {
          const button = document.querySelector('[data-codex-project-colour]');
          button.focus();
          button.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
          return document.querySelector('#codex-sidebar-project-colours')?.contains(document.activeElement);
        })()
        """) as? Bool
        XCTAssertEqual(opened, true)
        let closed = try await webView.evaluateJavaScript("""
        (() => {
          document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
          return !document.getElementById('codex-sidebar-project-colours')
            && document.activeElement.hasAttribute('data-codex-project-colour');
        })()
        """) as? Bool
        XCTAssertEqual(closed, true)
        let ariaExpanded = try await webView.evaluateJavaScript(
            "document.querySelector('[data-codex-project-colour]').getAttribute('aria-expanded')"
        ) as? String
        XCTAssertEqual(ariaExpanded, "false")
    }

    func testHighlightsRebindWhenCodexReplacesTheSidebar() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <html><body><aside role="navigation"><button>New chat</button>
          <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project"
            data-app-action-sidebar-project-label="Project"><span data-marquee-text>Project</span></div>
        </aside><main></main></body></html>
        """, clearLocalStorage: true)
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-codex-project-colour]').click();
        document.querySelector('[data-colour="Green"]').click();
        document.querySelector('aside').outerHTML = `<aside role="navigation"><button>New chat</button>
          <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project"
            data-app-action-sidebar-project-label="Project"><span data-marquee-text>Project</span></div>
        </aside>`;
        """)
        _ = try await webView.evaluateJavaScript(InjectionBundle.load().mountExpression)
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-codex-project-colour]')?.getAttribute('aria-expanded') === 'false'",
            in: webView
        )
        let colour = try await webView.evaluateJavaScript(
            "document.querySelector('[data-marquee-text]').style.getPropertyValue('--codex-project-highlight')"
        ) as? String
        XCTAssertEqual(colour, "#69b883")
    }
}
