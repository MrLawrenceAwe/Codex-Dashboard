import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class ThreadDashboardWebTests: SerializedDashboardWebTestCase {
    func testCompleteCatalogUsesClientPagingAndSearchesBeyondFirstPage() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let threads = (0..<65).map { index in
            ThreadSummary.fixture(
                id: "thread-\(index)",
                title: index == 64 ? "Needle outside first page" : "Thread \(index)",
                recencyTimestamp: Int64(65 - index)
            )
        }
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)
        let initial = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const initialCount = document.querySelectorAll('[data-thread-list] .dashboard-thread').length;
              const loadMoreVisible = !document.querySelector('[data-load-more]').hidden;
              document.querySelector('[data-load-more]').click();
              const expandedCount = document.querySelectorAll('[data-thread-list] .dashboard-thread').length;
              const search = document.querySelector('[data-dashboard-search]');
              search.value = 'Needle outside';
              search.dispatchEvent(new Event('input', { bubbles: true }));
              document.querySelector('[data-view="projects"]').click();
              return [
                initialCount,
                loadMoreVisible,
                expandedCount,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(initial)
        XCTAssertEqual(values[0] as? Int, 60)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Int, 65)
        let matchingID = try await webView.evaluateJavaScript(
            "document.querySelector('[data-thread-list] .dashboard-thread')?.dataset.threadId"
        ) as? String
        XCTAssertEqual(matchingID, "thread-64")
    }

    func testSearchResultsRemainPaged() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let threads = (0..<125).map { index in
            ThreadSummary.fixture(id: "matching-\(index)", title: "Matching thread \(index)")
        }
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const search = document.querySelector('[data-dashboard-search]');
              search.value = 'Matching';
              search.dispatchEvent(new Event('input', { bubbles: true }));
              document.querySelector('[data-view="projects"]').click();
              return true;
            })()
            """
        )
        let result = try await webView.evaluateJavaScript(
            """
            [
              document.querySelectorAll('[data-thread-list] .dashboard-thread').length,
              !document.querySelector('[data-load-more]').hidden,
            ]
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 60)
        XCTAssertEqual(values[1] as? Bool, true)
    }

    func testUnchangedSnapshotRetainsRenderedThreadElements() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [.fixture(id: "stable")])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              window.__stableThreadElement = document.querySelector('[data-thread-id="stable"]');
              window.__codexDashboard.applySnapshot(\(payload));
            })()
            """
        )

        try await Task.sleep(for: .milliseconds(50))
        let retained = try await webView.evaluateJavaScript(
            "window.__stableThreadElement === document.querySelector('[data-thread-id=\"stable\"]')"
        ) as? Bool
        XCTAssertEqual(retained, true)
    }

    func testClosedDashboardDefersThreadDOMUntilOpened() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "deferred-thread", isUnread: true),
        ])

        let closedState = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              return [
                document.querySelectorAll('[data-thread-list] .dashboard-thread').length,
                document.querySelector('[data-navigation-count]').textContent,
              ];
            })()
            """
        ) as? [Any]
        let closedValues = try XCTUnwrap(closedState)
        XCTAssertEqual(closedValues[0] as? Int, 0)
        XCTAssertEqual(closedValues[1] as? String, "1")

        let openedThreadID = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.open();
              return document.querySelector('[data-thread-list] .dashboard-thread')?.dataset.threadId;
            })()
            """
        ) as? String
        XCTAssertEqual(openedThreadID, "deferred-thread")
    }

    func testRestoresAndSavesDashboardPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-preferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let htmlURL = directory.appendingPathComponent("index.html")
        try Data(
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button>New chat</button></aside><main>Conversation</main>
            </body></html>
            """.utf8
        ).write(to: htmlURL)
        let webView = DashboardWebTestHarness.makeWebView()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: directory)
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let preferencesStored = try await webView.evaluateJavaScript(
            "try { localStorage.setItem('codex-dashboard.thread-preferences', JSON.stringify({ filterMode: 'unread', viewMode: 'recent', collapsedProjects: ['/tmp/project'], ignoredProjectPaths: ['/tmp/ignored-project'] })); true } catch (_) { false }"
        ) as? Bool
        XCTAssertEqual(preferencesStored, true)
        let injection = try DashboardInjectionPayload.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            ThreadSummary.fixture(id: "one", isUnread: true),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              try {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const restored = [
                document.querySelector('[data-filter="unread"]').classList.contains('is-active'),
                document.querySelector('[data-view="recent"]').classList.contains('is-active'),
              ];
              document.querySelector('[data-filter="all"]').click();
              document.querySelector('[data-view="projects"]').click();
              const saved = JSON.parse(localStorage.getItem('codex-dashboard.thread-preferences'));
              return JSON.stringify([restored, saved.filterMode, saved.viewMode, saved.collapsedProjects[0], saved.ignoredProjectPaths[0]]);
              } catch (error) {
                return JSON.stringify({ error: String(error), stack: error?.stack || '' });
              }
            })()
            """
        ) as? String
        let json = try XCTUnwrap(result)
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any]
        )
        XCTAssertEqual(values[0] as? [Bool], [true, true])
        XCTAssertEqual(values[1] as? String, "all")
        XCTAssertEqual(values[2] as? String, "projects")
        XCTAssertEqual(values[3] as? String, "/tmp/project")
        XCTAssertEqual(values[4] as? String, "/tmp/ignored-project")
    }

    func testCanonicalUnreadStateIncludesThreadMissingFromSidebar() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(
            id: "off-sidebar-unread",
            title: "Off-sidebar unread",
            preview: "Not mounted in the sidebar",
            isUnread: true
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
              return [
                document.querySelector('[data-filter-count="unread"]').textContent,
                document.querySelector('[data-thread-list] .dashboard-thread')?.dataset.threadId,
              ];
            })()
            """
        ) as? [String]

        XCTAssertEqual(result, ["1", "off-sidebar-unread"])
    }

    func testUnreadThreadAccessibleNameIncludesUnreadState() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "unread-thread", title: "Needs review", isUnread: true),
        ])

        let accessibleName = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              return document.querySelector('[data-thread-id="unread-thread"]').getAttribute('aria-label');
            })()
            """
        ) as? String

        XCTAssertEqual(accessibleName, "Unread. Open thread: Needs review")
    }

    func testUnreadFallbackDetectsSilentReactStateChange() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-one">Thread</button>
              </aside>
              <main>Conversation surface</main>
              <script>
                Object.defineProperty(document, 'visibilityState', {
                  configurable: true,
                  value: 'visible',
                });
              </script>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(id: "thread-one")
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              row.__reactFiber$test = {
                memoizedProps: { conversationId: 'thread-one', isUnread: true },
                return: null,
              };
              window.__codexDashboard.applySnapshot(\(payload));
              row.__reactFiber$test.memoizedProps = {
                conversationId: 'thread-one',
                isUnread: false,
              };
            })()
            """
        )

        try await Task.sleep(for: .milliseconds(1_700))
        let unreadCount = try await webView.evaluateJavaScript(
            #"document.querySelector('[data-filter-count="unread"]').textContent"#
        ) as? String

        XCTAssertEqual(unreadCount, "0")
    }

    func testChangedProjectsFilterIncludesEveryThreadFromChangedProjects() async throws {
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
                recencyTimestamp: 3,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "changed-project-thread-two",
                title: "Second changed project thread",
                preview: "Second",
                projectName: "Changed Project",
                projectPath: "/tmp/changed-project",
                recencyTimestamp: 2
            ),
            ThreadSummary.fixture(
                id: "clean-project-thread",
                title: "Clean project thread",
                preview: "Clean",
                projectName: "Clean Project",
                projectPath: "/tmp/clean-project",
                recencyTimestamp: 1
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="changedProjects"]').click();
              return [
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter-count="changedProjects"]').textContent,
                document.querySelector('[data-filter="changedProjects"]').textContent.trim(),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], [
            "changed-project-thread-one",
            "changed-project-thread-two",
        ])
        XCTAssertEqual(values[1] as? String, "1")
        XCTAssertEqual(values[2] as? String, "Changed projects 1")
    }

    func testNavigationShowsUncommittedChangesIndicatorForDirtyProjects() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside><main>Conversation surface</main>
            </body></html>
            """,
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(projectPath: "/tmp/dirty", workingTreeStatus: .hasChanges),
            .fixture(id: "clean", projectPath: "/tmp/clean", workingTreeStatus: .clean),
        ])

        let status = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const indicator = document.querySelector('[data-navigation-changes]');
              return [indicator.hidden, indicator.getAttribute('title')];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(status)
        XCTAssertEqual(values[0] as? Bool, false)
        XCTAssertEqual(values[1] as? String, "1 project has uncommitted changes")
    }

    func testIgnoredProjectIsRemovedFromChangeIndicatorsAndCanBeRestored() async throws {
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
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
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
        XCTAssertEqual(values[1] as? [AnyHashable], ["0", true, 0, "Restore"])
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
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-project-commit]').click();
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(100))
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.getElementById('codex-dashboard-page').classList.contains('is-open'),
              document.querySelector('[data-dashboard-notice]').textContent,
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

    func testProjectCommitActionDispatchesCodexNativeGitCommand() async throws {
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
                document.documentElement.dataset.command = '';
                document.documentElement.dataset.sidePanelCount = '0';
                window.__codexDashboardCommandDispatcher = (command, source) => {
                  document.documentElement.dataset.command = `${command}:${source}`;
                  return true;
                };
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
                recencyTimestamp: 5,
                runState: .running,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "off-sidebar-idle-thread",
                title: "Newest idle thread not mounted in the sidebar",
                projectPath: "/tmp/changed-project",
                recencyTimestamp: 4,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "idle-thread",
                title: "Older idle thread",
                projectPath: "/tmp/changed-project",
                recencyTimestamp: 2,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "clean-thread",
                title: "Clean project thread",
                projectPath: "/tmp/clean-project",
                recencyTimestamp: 1,
                workingTreeStatus: .clean
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let buttonCounts = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
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
              document.documentElement.dataset.command,
              document.documentElement.dataset.sidePanelCount,
              document.getElementById('codex-dashboard-page').classList.contains('is-open'),
            ]
            """
        ) as? [Any]

        let counts = try XCTUnwrap(buttonCounts)
        XCTAssertEqual(counts[0] as? Int, 1)
        XCTAssertEqual(counts[1] as? String, "Commit or push")
        let values = try XCTUnwrap(handoff)
        XCTAssertEqual(values[0] as? String, "local:off-sidebar-idle-thread")
        XCTAssertEqual(values[1] as? String, "git.commit:codex_dashboard")
        XCTAssertEqual(values[2] as? String, "0")
        XCTAssertEqual(values[3] as? Bool, false)
    }

    func testRunningThreadsUseCompactSummaryAndAreNotDuplicatedInMainList() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let threads = [
            ThreadSummary.fixture(
                id: "project-a-running-one",
                title: "First running thread",
                preview: "Running",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                recencyTimestamp: 4,
                runState: .running,
                workingTreeStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-running-two",
                title: "Second running thread",
                preview: "Running",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                recencyTimestamp: 3,
                runState: .running,
                workingTreeStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-idle",
                title: "Idle thread",
                preview: "Idle",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                recencyTimestamp: 2
            ),
            ThreadSummary.fixture(
                id: "project-b-running",
                title: "Other running thread",
                preview: "Running",
                projectName: "Project B",
                projectPath: "/tmp/project-b",
                recencyTimestamp: 1,
                runState: .running,
                workingTreeStatus: .clean
            ),
        ]
        let payload = try DashboardWebTestHarness.snapshotPayload(for: threads)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              return [
                document.querySelector('[data-running-count]').textContent,
                document.querySelector('[data-navigation-running-count]').textContent,
                document.querySelector('[data-navigation-running]').getAttribute('aria-label'),
                document.querySelectorAll('[data-running-list] .dashboard-thread.is-compact').length,
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-running-list] .dashboard-thread p') === null,
                document.querySelector('[data-filter-count="all"]').textContent,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "3")
        XCTAssertEqual(values[1] as? String, "3")
        XCTAssertEqual(values[2] as? String, "3 running threads")
        XCTAssertEqual(values[3] as? Int, 3)
        XCTAssertEqual(values[4] as? [String], ["project-a-idle"])
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertEqual(values[6] as? String, "1")
    }

    func testThreadRowOpensFromPointerOrKeyboardTarget() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-one">Thread</button>
              </aside>
              <main>Conversation surface</main>
              <script>
                document.documentElement.dataset.openCount = '0';
                document.querySelector('[data-app-action-sidebar-thread-id]').addEventListener('click', () => {
                  document.documentElement.dataset.openCount = String(
                    Number(document.documentElement.dataset.openCount) + 1
                  );
                });
              </script>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(id: "thread-one", title: "Keyboard target")
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const row = document.querySelector('[data-thread-list] .dashboard-thread');
              const contract = [row.getAttribute('role'), row.getAttribute('tabindex'), row.getAttribute('aria-label')];
              row.click();
              window.__codexDashboard.open();
              document.querySelector('[data-thread-list] .dashboard-thread')
                .dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
              return [contract, document.documentElement.dataset.openCount];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["button", "0", "Open thread: Keyboard target"])
        XCTAssertEqual(values[1] as? String, "2")
    }

}
