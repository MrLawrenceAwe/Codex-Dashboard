import Foundation
import XCTest
import WebKit

@testable import CodexDashboard

@MainActor
extension ChatOverviewWebTests {
    func testRemovedProjectHasNoChangeIndicatorAndAliasesShareOneGroup() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        var removed = ThreadSummary.fixture(id: "removed", projectName: "Other chats", checkoutPath: "/tmp/removed", isUnread: true, projectGitStatus: .uncommittedChanges)
        removed.projectGroupPath = nil
        var alias = ThreadSummary.fixture(id: "alias", projectName: "Mail Verify", checkoutPath: "/tmp/old-name", isUnread: true, projectGitStatus: .uncommittedChanges)
        alias.projectGroupPath = "/tmp/mail"
        let current = ThreadSummary.fixture(id: "current", projectName: "Mail Verify", checkoutPath: "/tmp/mail", isUnread: true, projectGitStatus: .uncommittedChanges)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [removed, alias, current])
        let result = try await webView.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.applyThreads((\(payload)).threads);
          window.__codexDashboard.openChatOverview();
          document.querySelector('[data-filter="changedProjects"]').click();
          const changed = [document.querySelector('[data-filter-count="changedProjects"]').textContent,
            [...document.querySelectorAll('[data-dashboard-git-project]')].map(row => row.dataset.dashboardGitProject)];
          document.querySelector('[data-filter="unread"]').click();
          return [...changed, [...document.querySelectorAll('[data-dashboard-project-group]')].map(row => row.dataset.dashboardProjectGroup),
            document.querySelectorAll('[data-open-thread]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "1")
        XCTAssertEqual(values[1] as? [String], ["/tmp/mail"])
        XCTAssertEqual(values[2] as? [String], ["", "/tmp/mail"])
        XCTAssertEqual(values[3] as? Int, 3)
    }

    func testUncommittedChangesShowCommitAction() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "local", checkoutPath: "/tmp/local", projectGitStatus: .uncommittedChanges),
        ])
        let result = try await webView.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.applyThreads((\(payload)).threads);
          window.__codexDashboard.openChatOverview();
          document.querySelector('[data-filter="changedProjects"]').click();
          const button = document.querySelector('[data-project-git-action]');
          return [button.textContent.trim(), button.title,
            document.querySelector('.dashboard-git-changes').textContent.trim()];
        })()
        """) as? [String]
        XCTAssertEqual(result, ["Commit", "Commit in this project’s repository", "Uncommitted"])
    }

    func testUnpushedCommitsAppearInLocalChangesWithPushAction() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "unpushed", checkoutPath: "/tmp/unpushed", projectGitStatus: .unpushedCommits),
            .fixture(id: "both", checkoutPath: "/tmp/both", projectGitStatus: .uncommittedChangesAndUnpushedCommits),
            .fixture(id: "clean", checkoutPath: "/tmp/clean", projectGitStatus: .clean),
        ])
        let result = try await webView.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.applyThreads((\(payload)).threads);
          window.__codexDashboard.openChatOverview();
          document.querySelector('[data-filter="changedProjects"]').click();
          return [document.querySelector('[data-filter-count="changedProjects"]').textContent,
            [...document.querySelectorAll('[data-thread-list] .dashboard-git-changes')].map(item => item.textContent.trim()),
            document.querySelectorAll('[data-thread-list] [data-project-git-action]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "2")
        XCTAssertEqual(values[1] as? [String], ["Unpushed", "Uncommitted · Unpushed"])
        XCTAssertEqual(values[2] as? Int, 2)
    }

    func testChangedProjectsFilterShowsOneGitActionPerChangedProject() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"></aside><main>Conversation surface</main>
            </body></html>
            """,
        )
        let threads = [
            ThreadSummary.fixture(
                id: "changed-project-thread-one",
                title: "First changed project thread",
                preview: "First",
                projectName: "Changed Project",
                checkoutPath: "/tmp/changed-project",
                recencyEpochMillis: 3,
                projectGitStatus: .uncommittedChanges
            ),
            ThreadSummary.fixture(
                id: "changed-project-thread-two",
                title: "Second changed project thread",
                preview: "Second",
                projectName: "Changed Project",
                checkoutPath: "/tmp/changed-project",
                recencyEpochMillis: 2
            ),
            ThreadSummary.fixture(
                id: "clean-project-thread",
                title: "Clean project thread",
                preview: "Clean",
                projectName: "Clean Project",
                checkoutPath: "/tmp/clean-project",
                recencyEpochMillis: 1
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="changedProjects"]').click();
              return [
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.openThread),
                document.querySelectorAll('[data-thread-list] .dashboard-git-project').length,
                document.querySelectorAll('[data-thread-list] [data-project-git-action]').length,
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-filter="changedProjects"]').textContent.trim(),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], [])
        XCTAssertEqual(values[1] as? Int, 1)
        XCTAssertEqual(values[2] as? Int, 1)
        XCTAssertEqual(values[3] as? String, "1")
        XCTAssertEqual(values[4] as? String, "Local changes 1")
    }

    func testChangedProjectsDoesNotOfferLoadMoreForAdditionalTasksInOneProject() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let threads = (0..<11).map { index in
            ThreadSummary.fixture(
                id: "changed-project-thread-\(index)",
                projectName: "Changed Project",
                checkoutPath: "/tmp/changed-project",
                recencyEpochMillis: Int64(11 - index),
                projectGitStatus: index == 0 ? .uncommittedChanges : .clean
            )
        }
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="changedProjects"]').click();
              return [
                document.querySelectorAll('[data-thread-list] .dashboard-git-project').length,
                document.querySelector('[data-load-more]').hidden,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 1)
        XCTAssertEqual(values[1] as? Bool, true)
    }

    func testHiddenChangeIndicatorsKeepGitActionsAvailableAndCanBeRestored() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let projectPath = "/tmp/muted-project"
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(checkoutPath: projectPath, projectGitStatus: .uncommittedChanges),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="changedProjects"]').click();
              const before = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelectorAll('[data-project-git-action]').length,
                document.querySelector('[data-project-indicators]').textContent.trim(),
              ];
              document.querySelector('[data-project-indicators]').click();
              const muted = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-navigation-changes]').hidden,
                document.querySelectorAll('[data-project-git-action]').length,
                document.querySelector('[data-project-indicators]').textContent.trim(),
                document.querySelector('.dashboard-hidden-indicators')?.open,
                document.querySelector('.dashboard-hidden-indicators summary')?.textContent.trim(),
                document.querySelectorAll('.dashboard-git-project .dashboard-git-changes').length,
              ];
              document.querySelector('[data-project-indicators]').click();
              const restored = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-navigation-changes]').hidden,
                document.querySelectorAll('[data-project-git-action]').length,
                document.querySelector('[data-project-indicators]').textContent.trim(),
                document.querySelectorAll('.dashboard-git-project .dashboard-git-changes').length,
              ];
              return [before, muted, restored];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [AnyHashable], ["1", 1, "Hide change indicators"])
        XCTAssertEqual(values[1] as? [AnyHashable], ["1", true, 1, "Show change indicators", false, "Indicators hidden1", 0])
        XCTAssertEqual(values[2] as? [AnyHashable], ["1", false, 1, "Hide change indicators", 1])
    }


    func testDashboardPushUsesWorkerWithoutOpeningAChat() async throws {
        let webView = try await directGitFixture()
        _ = try await webView.evaluateJavaScript("document.querySelector('[data-project-git-action]').click()")
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-chat-overview-notice]').textContent === 'Pushed.' && !document.querySelector('[data-project-git-action]')",
            in: webView)
        let result = try await webView.evaluateJavaScript("""
        [window.pushes === 1, window.__codexDashboard.isOpen(), !window.openedChat,
          !document.querySelector('[aria-label="Git actions"]'), !document.querySelector('[data-project-git-action]')]
        """) as? [Bool]
        XCTAssertEqual(result, [true, true, true, true, true])
    }

    func testDashboardPushFailureKeepsProjectVisibleForRetry() async throws {
        let webView = try await directGitFixture()
        _ = try await webView.evaluateJavaScript("window.pushError = true; document.querySelector('[data-project-git-action]').click()")
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-chat-overview-notice]').textContent === 'Rejected by remote' && !document.querySelector('[data-project-git-action]').disabled",
            in: webView)
        let result = try await webView.evaluateJavaScript(
            "[window.pushes === 1, window.__codexDashboard.isOpen(), !window.openedChat]") as? [Bool]
        XCTAssertEqual(result, [true, true, true])
    }

    private func directGitFixture() async throws -> WKWebView {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><body>
          <aside role="navigation">
            <button class="sidebar-item">New chat</button>
            <button data-app-action-sidebar-thread-id="local:project-thread" onclick="window.openedChat = true">Project chat</button>
          </aside><main>Conversation surface</main>
          <script>
            window.pushes = 0;
            const listeners = new Set();
            window.electronBridge = {
              subscribeToWorkerMessages(worker, listener) { listeners.add(listener); return () => listeners.delete(listener); },
              sendWorkerMessageFromView(worker, message) {
                if (message.type !== 'worker-request') return Promise.resolve();
                const { id, method } = message.request;
                let value;
                switch (method) {
                  case 'current-branch': value = { branch: 'main', isDetached: false }; break;
                  case 'upstream-branch': value = { branch: 'main', upstream: { branch: 'origin/main' } }; break;
                  case 'push':
                    window.pushes++;
                    value = window.pushError
                      ? { status: 'error', execOutput: { output: 'Rejected by remote' } }
                      : { status: 'success' };
                    break;
                  case 'status-summary': value = { type: 'success', stagedCount: 0, unstagedCount: 0, untrackedCount: 0 }; break;
                  case 'branch-ahead-count': value = { commitsAhead: window.pushes && !window.pushError ? 0 : 1 }; break;
                  default: value = {};
                }
                setTimeout(() => listeners.forEach(listener => listener({
                  type: 'worker-response', workerId: 'git',
                  response: { id, method, result: { type: 'ok', value } }
                })), 10);
                return Promise.resolve();
              }
            };
          </script>
        </body></html>
        """)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "project-thread", checkoutPath: "/tmp/project", runState: .running,
                     projectGitStatus: .unpushedCommits),
        ])
        _ = try await webView.evaluateJavaScript("""
        window.__codexDashboard.applyThreads((\(payload)).threads);
        window.__codexDashboard.openChatOverview();
        document.querySelector('[data-filter="changedProjects"]').click();
        """)
        return webView
    }
}
