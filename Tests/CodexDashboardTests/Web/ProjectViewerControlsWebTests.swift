import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class ProjectViewerControlsWebTests: SerializedDashboardWebTestCase {
    func testHeaderAndSidebarUseTheirOwnRootsAndRepairAfterNavigation() async throws {
        let view = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><body>
          <aside><nav>
            <div class="sidebar-item"><button>New chat</button></div>
            <div id="project" data-app-action-sidebar-project-row data-app-action-sidebar-project-id="saved"
              data-app-action-sidebar-project-label="Saved project"><span>Saved project</span></div>
            <div id="remote" data-app-action-sidebar-project-row data-app-action-sidebar-project-id="remote"
              data-app-action-sidebar-project-label="Remote project"><span>Remote project</span></div>
          </nav></aside>
          <main>
            <div data-app-shell-header-toolbar><div id="actions">
              <div data-app-shell-focus-area="main"><button aria-label="Chat actions">…</button></div>
            </div></div>
            <div id="composer"><textarea></textarea></div>
          </main>
          <script>
            window.selected = 'worktree';
            window.rowActivations = 0;
            document.getElementById('composer').__reactFiber$test = {
              get memoizedProps() { return { conversationId: window.selected }; }
            };
            for (const [row, id, projectKind, path] of [
              ['project', 'saved', 'local', '/tmp/saved project'],
              ['remote', 'remote', 'remote', '/tmp/remote project']
            ]) {
              const element = document.getElementById(row);
              element.__reactFiber$test = { memoizedProps: { group: { projectId: id, projectKind, path } } };
              element.addEventListener('click', () => window.rowActivations++);
              element.addEventListener('pointerdown', () => window.rowActivations++);
            }
          </script>
        </body></html>
        """)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "worktree", checkoutPath: "/tmp/worktree"),
            .fixture(id: "other", checkoutPath: "/tmp/ordinary-folder"),
        ])
        let results = try await view.evaluateJavaScript("""
        (() => {
          const dashboard = window.__codexDashboard;
          dashboard.applyThreads((\(payload)).threads);
          function activate(selector, sidebar = false) {
            const button = document.querySelector(selector);
            if (sidebar) {
              button.dispatchEvent(new Event('pointerdown', { bubbles: true }));
              button.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            } else button.click();
            const request = JSON.parse(dashboard.pendingProjectViewerRequest());
            dashboard.acknowledgeProjectViewerRequest(request.id);
            return request;
          }
          const header = activate('#actions [data-dashboard-viewer-control="header"]');
          const sidebar = activate('#project [data-dashboard-viewer-control="sidebar"]', true);
          return [header.path, header.threadID, sidebar.path, sidebar.projectID, window.rowActivations,
            document.querySelector('#remote [data-dashboard-viewer-control]') === null];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(results, ["/tmp/worktree", "worktree", "/tmp/saved project", "saved", 0, true])

        _ = try await view.evaluateJavaScript("""
        window.selected = 'other';
        const replacement = document.getElementById('actions').cloneNode(true);
        replacement.querySelector('[data-dashboard-viewer-control]').remove();
        document.getElementById('actions').replaceWith(replacement);
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelectorAll('#actions [data-dashboard-viewer-control]').length === 1", in: view
        )
        let checkout = try await view.evaluateJavaScript("""
        document.querySelector('#actions [data-dashboard-viewer-control]').click();
        JSON.parse(window.__codexDashboard.pendingProjectViewerRequest()).path;
        """) as? String
        XCTAssertEqual(checkout, "/tmp/ordinary-folder")

        let remaining = try await view.evaluateJavaScript("""
        window.__codexDashboard.destroy();
        document.querySelectorAll('[data-dashboard-viewer-control]').length;
        """) as? Int
        XCTAssertEqual(remaining, 0)
    }
}
