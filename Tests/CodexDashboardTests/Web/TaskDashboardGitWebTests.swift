import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension TaskDashboardWebTests {
    func testChangedProjectsFilterShowsOneCommitActionPerChangedProject() async throws {
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
                projectPath: "/tmp/changed-project",
                recencyEpochMillis: 3,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "changed-project-thread-two",
                title: "Second changed project thread",
                preview: "Second",
                projectName: "Changed Project",
                projectPath: "/tmp/changed-project",
                recencyEpochMillis: 2
            ),
            ThreadSummary.fixture(
                id: "clean-project-thread",
                title: "Clean project thread",
                preview: "Clean",
                projectName: "Clean Project",
                projectPath: "/tmp/clean-project",
                recencyEpochMillis: 1
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="changedProjects"]').click();
              return [
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelectorAll('[data-thread-list] .dashboard-git-project').length,
                document.querySelectorAll('[data-thread-list] [data-project-commit]').length,
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
        XCTAssertEqual(values[4] as? String, "Changed projects 1")
    }

    func testIgnoredProjectIsRemovedFromChangeIndicatorsAndCanBeUnignored() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let projectPath = "/tmp/ignored-project"
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(projectPath: projectPath, workingTreeStatus: .hasChanges),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="changedProjects"]').click();
              const before = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelectorAll('[data-project-commit]').length,
                document.querySelector('[data-project-ignore]').textContent.trim(),
              ];
              document.querySelector('[data-project-ignore]').click();
              const ignored = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-navigation-changes]').hidden,
                document.querySelectorAll('[data-project-commit]').length,
                document.querySelector('[data-project-ignore]').textContent.trim(),
                document.querySelector('.dashboard-ignored-projects')?.open,
                document.querySelector('.dashboard-ignored-projects summary')?.textContent.trim(),
              ];
              document.querySelector('[data-project-ignore]').click();
              const restored = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-navigation-changes]').hidden,
                document.querySelectorAll('[data-project-commit]').length,
                document.querySelector('[data-project-ignore]').textContent.trim(),
              ];
              return [before, ignored, restored];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [AnyHashable], ["1", 1, "Ignore"])
        XCTAssertEqual(values[1] as? [AnyHashable], ["0", true, 0, "Unignore", false, "Ignored1"])
        XCTAssertEqual(values[2] as? [AnyHashable], ["1", false, 1, "Ignore"])
    }

    func testUnavailableCommitActionDoesNotNavigateAwayFromDashboard() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(projectPath: "/tmp/changed", workingTreeStatus: .hasChanges),
        ])

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="changedProjects"]').click();
              document.querySelector('[data-project-commit]').click();
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(100))
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.getElementById('codex-dashboard-page').classList.contains('is-open'),
              document.querySelector('[data-commit-notice]').textContent,
            ]
            """
        ) as? [Any]

        let values = try XCTUnwrap(state)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(
            values[1] as? String,
            "Commit or push is not available in this Codex version. Open a project thread and use its Git controls instead."
        )
    }

    func testCommitFailureAfterThreadNavigationIsRenderedImmediately() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:idle-thread">Idle thread</button>
              </aside>
              <main>
                <button type="button" data-slot="thread-summary-panel-item-button">Commit or push</button>
              </main>
              <script>
                const row = document.querySelector('[data-app-action-sidebar-thread-id]');
                row.addEventListener('click', () => {
                  row.setAttribute('aria-current', 'page');
                  document.querySelector('[data-slot="thread-summary-panel-item-button"]')?.remove();
                });
              </script>
            </body></html>
            """,
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "idle-thread",
                projectPath: "/tmp/changed-project",
                workingTreeStatus: .hasChanges
            ),
        ])

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="changedProjects"]').click();
              document.querySelector('[data-project-commit]').click();
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(250))
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.getElementById('codex-dashboard-page').classList.contains('is-open'),
              document.querySelector('[data-commit-notice]').hidden,
              document.querySelector('[data-commit-notice]').textContent,
            ]
            """
        ) as? [Any]

        XCTAssertEqual(
            try XCTUnwrap(state) as? [AnyHashable],
            [true, false, "The project thread opened, but Codex could not start Commit or push."]
        )
    }

    func testProjectCommitActionUsesCodexNativeGitControls() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:idle-thread">Idle thread</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:running-thread">Running thread</button>
              </aside>
              <main>
                <button type="button" aria-label="Toggle side panel">Side panel</button>
                <div id="composer-host"><textarea placeholder="Do anything"></textarea></div>
              </main>
              <script>
                document.documentElement.dataset.selectedThread = '';
                document.documentElement.dataset.sidePanelCount = '0';
                document.documentElement.dataset.commitCount = '0';
                const activeThreadProps = { conversationId: 'initial-thread' };
                document.getElementById('composer-host').__reactFiber$test = {
                  memoizedProps: activeThreadProps,
                  return: null,
                };
                window.addEventListener('message', (event) => {
                  if (event.data?.type !== 'navigate-to-route') return;
                  const threadID = decodeURIComponent(event.data.path.split('/').at(-1));
                  activeThreadProps.conversationId = threadID;
                  document.documentElement.dataset.selectedThread = `local:${threadID}`;
                });
                document.querySelectorAll('[data-app-action-sidebar-thread-id]').forEach((row) => {
                  row.addEventListener('click', () => {
                    document.querySelectorAll('[data-app-action-sidebar-thread-id]')
                      .forEach((candidate) => candidate.removeAttribute('aria-current'));
                    row.setAttribute('aria-current', 'page');
                    document.documentElement.dataset.selectedThread = row.dataset.appActionSidebarThreadId;
                  });
                });
                document.querySelector('[aria-label="Toggle side panel"]').addEventListener('click', () => {
                  document.documentElement.dataset.sidePanelCount = String(
                    Number(document.documentElement.dataset.sidePanelCount) + 1
                  );
                  const environment = document.createElement('button');
                  environment.type = 'button';
                  environment.textContent = 'Environment';
                  environment.setAttribute('aria-expanded', 'false');
                  environment.addEventListener('click', () => {
                    environment.setAttribute('aria-expanded', 'true');
                    const commit = document.createElement('button');
                    commit.type = 'button';
                    commit.dataset.slot = 'thread-summary-panel-item-button';
                    commit.textContent = 'Commit or push';
                    commit.addEventListener('click', () => {
                      document.documentElement.dataset.commitCount = String(
                        Number(document.documentElement.dataset.commitCount) + 1
                      );
                    });
                    document.body.append(commit);
                  });
                  document.body.append(environment);
                });
              </script>
            </body></html>
            """,
        )
        let threads = [
            ThreadSummary.fixture(
                id: "running-thread",
                title: "Newer running thread",
                projectPath: "/tmp/changed-project",
                recencyEpochMillis: 5,
                runState: .running,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "off-sidebar-idle-thread",
                title: "Newest idle thread not mounted in the sidebar",
                projectPath: "/tmp/changed-project",
                recencyEpochMillis: 4,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "idle-thread",
                title: "Older idle thread",
                projectPath: "/tmp/changed-project",
                recencyEpochMillis: 2,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "clean-thread",
                title: "Clean project thread",
                projectPath: "/tmp/clean-project",
                recencyEpochMillis: 1,
                workingTreeStatus: .clean
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let buttonCounts = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const buttons = [...document.querySelectorAll('[data-project-commit]')];
              const result = [buttons.length, buttons[0]?.textContent.trim()];
              buttons[0].click();
              return result;
            })()
            """
        ) as? [Any]
        try await Task.sleep(for: .milliseconds(700))
        let handoff = try await webView.evaluateJavaScript(
            """
            [
              document.documentElement.dataset.selectedThread,
              document.documentElement.dataset.sidePanelCount,
              document.documentElement.dataset.commitCount,
              document.getElementById('codex-dashboard-page').classList.contains('is-open'),
            ]
            """
        ) as? [Any]

        let counts = try XCTUnwrap(buttonCounts)
        XCTAssertEqual(counts[0] as? Int, 1)
        XCTAssertEqual(counts[1] as? String, "Commit or push")
        let values = try XCTUnwrap(handoff)
        XCTAssertEqual(values[0] as? String, "local:off-sidebar-idle-thread")
        XCTAssertEqual(values[1] as? String, "1")
        XCTAssertEqual(values[2] as? String, "1")
        XCTAssertEqual(values[3] as? Bool, false)
    }

    func testRunningChangedProjectUsesConsistentCountAndDefersCommitAction() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "running-dirty",
                projectPath: "/tmp/running-dirty",
                runState: .running,
                workingTreeStatus: .hasChanges
            ),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="changedProjects"]').click();
              const commit = document.querySelector('[data-project-commit]');
              return [
                document.querySelector('[data-summary-count="changed"]').textContent,
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                Boolean(document.querySelector('.dashboard-git-project')),
                commit.disabled,
                commit.textContent.trim(),
              ];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], ["1", "1", true, true, "Task running"])
    }

}
