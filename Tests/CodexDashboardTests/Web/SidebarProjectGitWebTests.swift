import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class SidebarProjectGitWebTests: SerializedDashboardWebTestCase {
    func testGitMarkersFollowProjectIdentityStatusAndSidebarReplacement() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <html><body><aside><button>New chat</button>
          <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dirty"
            data-app-action-sidebar-project-label="Same name"><div style="overflow:hidden; width:80px"><span data-marquee-text>Same name</span></div></div>
          <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="ahead"
            data-app-action-sidebar-project-label="Same name"><div style="overflow:hidden; width:80px"><span data-marquee-text>Same name</span></div></div>
          <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="clean"
            data-app-action-sidebar-project-label="Same name"><div style="overflow:hidden; width:80px"><span data-marquee-text>Same name</span></div></div>
        </aside><main></main></body></html>
        """, baseURL: URL(string: "https://sidebar-git.codex-dashboard.test"), clearLocalStorage: true)
        _ = try await webView.evaluateJavaScript("""
        for (const [id, path] of [['dirty', '/tmp/project'], ['ahead', '/tmp/ahead'], ['clean', '/tmp/clean']]) {
          document.querySelector(`[data-app-action-sidebar-project-id="${id}"]`).__reactFiber$test = {
            memoizedProps: { group: { projectId: id, projectKind: 'local', path } }, return: null,
          };
        }
        """)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "dirty-chat", projectID: "dirty", projectGitStatus: .uncommittedChanges),
            .fixture(id: "ahead-chat", checkoutPath: "/tmp/ahead", projectID: "ahead", projectGitStatus: .unpushedCommits),
            .fixture(id: "clean-chat", checkoutPath: "/tmp/clean", projectID: "clean"),
        ])
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(payload)).threads.map(({ projectID, ...thread }) => thread))")
        let initial = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('[data-codex-project-git-status]')].map(marker =>
          marker.parentElement.dataset.appActionSidebarProjectId + ':' + marker.title)
        """) as? [String]
        let outsideClippedNames = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('[data-codex-project-git-status]')].every(marker =>
          marker.parentElement.hasAttribute('data-app-action-sidebar-project-row')
          && getComputedStyle(marker).opacity === '1'
          && getComputedStyle(marker).visibility === 'visible')
        """) as? Bool
        XCTAssertEqual(outsideClippedNames, true)
        XCTAssertEqual(initial, ["dirty:Same name: Uncommitted changes", "ahead:Same name: Unpushed commits"])

        _ = try await webView.evaluateJavaScript("""
        window.__codexDashboard.openChatOverview();
        document.querySelector('[data-filter="changedProjects"]').click();
        document.querySelector('[data-project-indicators="/tmp/project"]').click();
        window.__codexDashboard.applyThreads((\(payload)).threads);
        """)
        let hidden = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('[data-codex-project-git-status]')].map(marker =>
          marker.parentElement.dataset.appActionSidebarProjectId)
        """) as? [String]
        XCTAssertEqual(hidden, ["ahead"])
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.destroy()")
        _ = try await webView.evaluateJavaScript(InjectionBundle.load().mountExpression)
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(payload)).threads)")
        let persisted = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('[data-codex-project-git-status]')].map(marker =>
          marker.parentElement.dataset.appActionSidebarProjectId)
        """) as? [String]
        XCTAssertEqual(persisted, ["ahead"])
        _ = try await webView.evaluateJavaScript("""
        window.__codexDashboard.openChatOverview();
        document.querySelector('[data-project-indicators="/tmp/project"]').click();
        """)

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('aside').outerHTML = document.querySelector('aside').outerHTML;
        document.querySelectorAll('[data-codex-project-git-status]').forEach(marker => marker.remove());
        for (const [id, path] of [['dirty', '/tmp/project'], ['ahead', '/tmp/ahead'], ['clean', '/tmp/clean']]) {
          document.querySelector(`[data-app-action-sidebar-project-id="${id}"]`).__reactFiber$test = {
            memoizedProps: { group: { projectId: id, projectKind: 'local', path } }, return: null,
          };
        }
        window.__codexDashboard.ensureMounted();
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelectorAll('[data-codex-project-git-status]').length === 2", in: webView
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-app-action-sidebar-project-id="dirty"]').innerHTML =
          '<span data-marquee-text>Renamed</span>';
        document.querySelector('[data-app-action-sidebar-project-id="dirty"]')
          .setAttribute('data-app-action-sidebar-project-label', 'Renamed');
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-app-action-sidebar-project-id=dirty] [data-codex-project-git-status]')?.title === 'Renamed: Uncommitted changes'", in: webView
        )
        let updated = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "dirty-chat", projectID: "dirty", projectGitStatus: .clean),
            .fixture(id: "ahead-chat", checkoutPath: "/tmp/ahead", projectID: "ahead", projectGitStatus: .uncommittedChangesAndUnpushedCommits),
        ])
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(updated)).threads)")
        let remaining = try await webView.evaluateJavaScript(
            "[...document.querySelectorAll('[data-codex-project-git-status]')].map(marker => marker.title)"
        ) as? [String]
        XCTAssertEqual(remaining, ["Same name: Uncommitted changes and unpushed commits"])
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.destroy()")
        let count = try await webView.evaluateJavaScript(
            "document.querySelectorAll('[data-codex-project-git-status]').length"
        ) as? Int
        XCTAssertEqual(count, 0)
    }
}
