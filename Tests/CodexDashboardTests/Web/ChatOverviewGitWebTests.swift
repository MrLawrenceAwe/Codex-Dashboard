import Foundation
import XCTest

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
            document.querySelectorAll('[data-thread-id]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "1")
        XCTAssertEqual(values[1] as? [String], ["/tmp/mail"])
        XCTAssertEqual(values[2] as? [String], ["", "/tmp/mail"])
        XCTAssertEqual(values[3] as? Int, 3)
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
            document.querySelectorAll('[data-thread-list] [data-project-commit]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "2")
        XCTAssertEqual(values[1] as? [String], ["Unpushed", "Uncommitted · Unpushed"])
        XCTAssertEqual(values[2] as? Int, 2)
    }

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
                document.querySelectorAll('[data-project-commit]').length,
                document.querySelector('[data-project-indicators]').textContent.trim(),
              ];
              document.querySelector('[data-project-indicators]').click();
              const muted = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-navigation-changes]').hidden,
                document.querySelectorAll('[data-project-commit]').length,
                document.querySelector('[data-project-indicators]').textContent.trim(),
                document.querySelector('.dashboard-hidden-indicators')?.open,
                document.querySelector('.dashboard-hidden-indicators summary')?.textContent.trim(),
                document.querySelectorAll('.dashboard-git-project .dashboard-git-changes').length,
              ];
              document.querySelector('[data-project-indicators]').click();
              const restored = [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-navigation-changes]').hidden,
                document.querySelectorAll('[data-project-commit]').length,
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

    func testMissingGitActionsReportsSpecificFailure() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:idle-thread">Idle thread</button>
              </aside>
              <main>Conversation surface</main>
              <script>
                const row = document.querySelector('[data-app-action-sidebar-thread-id]');
                row.addEventListener('click', () => {
                  row.setAttribute('aria-current', 'page');
                });
              </script>
            </body></html>
            """,
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "idle-thread",
                checkoutPath: "/tmp/changed-project",
                projectGitStatus: .uncommittedChanges
            ),
        ])

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="changedProjects"]').click();
              document.querySelector('[data-project-commit]').click();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-chat-overview-notice]').textContent === 'Codex did not show Git actions for the project chat.'",
            in: webView,
            timeout: .seconds(15)
        )
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.getElementById('codex-dashboard-chat-overview-page').classList.contains('is-open'),
              document.querySelector('[data-chat-overview-notice]').hidden,
              document.querySelector('[data-chat-overview-notice]').textContent,
            ]
            """
        ) as? [Any]

        XCTAssertEqual(
            try XCTUnwrap(state) as? [AnyHashable],
            [true, false, "Codex did not show Git actions for the project chat."]
        )
    }

    func testProjectCommitRoutesPastHiddenSidebarCopyAndUsesCodexGitActionsMenu() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:idle-thread">Idle thread</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:running-thread">Running thread</button>
                <div hidden>
                  <button class="sidebar-item" data-app-action-sidebar-thread-id="local:off-sidebar-idle-thread">Stale workspace chat</button>
                </div>
              </aside>
              <main>
                <button type="button" aria-label="Git actions">Git</button>
                <div id="composer-host"><textarea placeholder="Do anything"></textarea></div>
              </main>
              <script>
                document.documentElement.dataset.selectedThread = '';
                document.documentElement.dataset.gitMenuCount = '0';
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
                    if (row.closest('[hidden]')) document.documentElement.dataset.staleRowClicked = 'true';
                    document.querySelectorAll('[data-app-action-sidebar-thread-id]')
                      .forEach((candidate) => candidate.removeAttribute('aria-current'));
                    row.setAttribute('aria-current', 'page');
                    document.documentElement.dataset.selectedThread = row.dataset.appActionSidebarThreadId;
                  });
                });
                document.querySelector('[aria-label="Git actions"]').addEventListener('pointerdown', () => {
                  document.querySelector('[aria-label="Git actions"]').setAttribute('aria-controls', 'git-menu');
                  document.documentElement.dataset.gitMenuCount = String(
                    Number(document.documentElement.dataset.gitMenuCount) + 1
                  );
                  const menu = document.createElement('div');
                  menu.id = 'git-menu';
                  menu.setAttribute('role', 'menu');
                  menu.innerHTML = '<div role="menuitem">Commit</div><div role="menuitem">Push</div>';
                  menu.firstElementChild.addEventListener('click', () => {
                    document.documentElement.dataset.commitOpened = 'true';
                    menu.remove();
                  });
                  document.body.append(menu);
                });
              </script>
            </body></html>
            """,
        )
        let threads = [
            ThreadSummary.fixture(
                id: "running-thread",
                title: "Newer running thread",
                checkoutPath: "/tmp/changed-project",
                recencyEpochMillis: 5,
                runState: .running,
                projectGitStatus: .uncommittedChanges
            ),
            ThreadSummary.fixture(
                id: "off-sidebar-idle-thread",
                title: "Newest idle thread not mounted in the sidebar",
                checkoutPath: "/tmp/changed-project",
                recencyEpochMillis: 4,
                projectGitStatus: .uncommittedChanges
            ),
            ThreadSummary.fixture(
                id: "idle-thread",
                title: "Older idle thread",
                checkoutPath: "/tmp/changed-project",
                recencyEpochMillis: 2,
                projectGitStatus: .uncommittedChanges
            ),
            ThreadSummary.fixture(
                id: "clean-thread",
                title: "Clean project thread",
                checkoutPath: "/tmp/clean-project",
                recencyEpochMillis: 1,
                projectGitStatus: .clean
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let buttonCounts = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="changedProjects"]').click();
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
              document.documentElement.dataset.gitMenuCount,
              document.documentElement.dataset.commitOpened,
              document.getElementById('codex-dashboard-chat-overview-page').classList.contains('is-open'),
              document.documentElement.dataset.staleRowClicked || 'false',
            ]
            """
        ) as? [Any]

        let counts = try XCTUnwrap(buttonCounts)
        XCTAssertEqual(counts[0] as? Int, 1)
        XCTAssertEqual(counts[1] as? String, "Commit or push")
        let values = try XCTUnwrap(handoff)
        XCTAssertEqual(values[0] as? String, "local:off-sidebar-idle-thread")
        XCTAssertEqual(values[1] as? String, "1")
        XCTAssertEqual(values[2] as? String, "true")
        XCTAssertEqual(values[3] as? Bool, false)
        XCTAssertEqual(values[4] as? String, "false")
    }

    func testProjectCommitWaitsForGitActionsMenu() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:idle-thread">Idle thread</button>
              </aside>
              <main id="task-surface"></main>
              <div role="menu"><div role="menuitem">Unrelated action</div></div>
              <script>
                document.querySelector('[data-app-action-sidebar-thread-id]').addEventListener('click', (event) => {
                  event.currentTarget.setAttribute('aria-current', 'page');
                  setTimeout(() => {
                    const menu = document.createElement('button');
                    menu.setAttribute('aria-label', 'Git actions');
                    menu.setAttribute('aria-controls', 'git-menu');
                    menu.addEventListener('pointerdown', () => {
                      setTimeout(() => {
                        const actions = document.createElement('div');
                        actions.id = 'git-menu';
                        actions.setAttribute('role', 'menu');
                        actions.innerHTML = '<div role="menuitem" aria-disabled="true">Commit</div><div role="menuitem">Push</div>';
                        const commit = actions.firstElementChild;
                        commit.addEventListener('click', () => {
                          document.documentElement.dataset.commitOpened = commit.getAttribute('aria-disabled') === 'true'
                            ? 'clicked-while-disabled' : 'true';
                          actions.remove();
                        });
                        document.body.append(actions);
                        setTimeout(() => {
                          const replacement = actions.cloneNode(true);
                          replacement.firstElementChild.setAttribute('aria-disabled', 'false');
                          replacement.firstElementChild.addEventListener('click', () => {
                            document.documentElement.dataset.commitOpened = 'true';
                            replacement.remove();
                          });
                          actions.replaceWith(replacement);
                        }, 150);
                      }, 150);
                    });
                    document.getElementById('task-surface').append(menu);
                  }, 250);
                });
              </script>
            </body></html>
            """,
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "idle-thread", checkoutPath: "/tmp/changed", projectGitStatus: .uncommittedChanges),
        ])

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="changedProjects"]').click();
              document.querySelector('[data-project-commit]').click();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.documentElement.dataset.commitOpened === 'true'",
            in: webView,
            timeout: .seconds(5)
        )
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.documentElement.dataset.commitOpened,
              document.getElementById('codex-dashboard-chat-overview-page').classList.contains('is-open'),
            ]
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(state) as? [AnyHashable], ["true", false])
    }

    func testRunningChangedProjectUsesConsistentCountAndDefersCommitAction() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "running-dirty",
                checkoutPath: "/tmp/running-dirty",
                runState: .running,
                projectGitStatus: .uncommittedChanges
            ),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="changedProjects"]').click();
              const commit = document.querySelector('[data-project-commit]');
              return [
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                Boolean(document.querySelector('.dashboard-git-project')),
                commit.disabled,
                commit.textContent.trim(),
              ];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], ["1", true, true, "Chat running"])
    }

}
