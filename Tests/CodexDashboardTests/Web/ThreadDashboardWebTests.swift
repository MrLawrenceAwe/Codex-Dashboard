import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class ThreadDashboardWebTests: SerializedDashboardWebTestCase {
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

    func testNativeSidebarProjectsExposeExpandedAndCollapsedChevrons() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row aria-expanded="true">Expanded project</div>
                <div data-app-action-sidebar-project-row aria-expanded="false">Collapsed project</div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const rows = [...document.querySelectorAll('[data-app-action-sidebar-project-row]')];
              return rows.map((row) => {
                const style = getComputedStyle(row, '::before');
                return [style.content, style.transform, style.width, style.height];
              });
            })()
            """
        ) as? [[String]]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0][0], #""""#)
        XCTAssertEqual(values[1][0], #""""#)
        XCTAssertNotEqual(values[0][1], values[1][1])
        XCTAssertEqual(values[0][2], "6px")
        XCTAssertEqual(values[0][3], "6px")
    }

    func testCompleteCatalogUsesClientPagingAndSearchesBeyondFirstPage() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let threads = (0..<65).map { index in
            ThreadSummary.fixture(
                id: "thread-\(index)",
                title: index == 64 ? "Needle outside first page" : "Thread \(index)",
                recencyTimestampMilliseconds: Int64(65 - index),
                runState: .running
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
              document.querySelector('[data-filter="running"]').click();
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
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let threads = (0..<125).map { index in
            ThreadSummary.fixture(
                id: "matching-\(index)",
                title: "Matching thread \(index)",
                runState: .running
            )
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
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
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
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "deferred-thread", isUnread: true, runState: .running),
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

    func testRestoresAndSavesDashboardPreferencesWithoutViewMode() async throws {
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
        let injection = try DashboardInjectionResources.load()
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
              const restored = document.querySelector('[data-filter="unread"]').classList.contains('is-active');
              document.querySelector('[data-filter="running"]').click();
              const saved = JSON.parse(localStorage.getItem('codex-dashboard.thread-preferences'));
              return JSON.stringify([restored, saved.filterMode, Object.hasOwn(saved, 'viewMode'), saved.collapsedProjects[0], saved.ignoredProjectPaths[0], document.querySelector('[data-view]') === null]);
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
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "running")
        XCTAssertEqual(values[2] as? Bool, false)
        XCTAssertEqual(values[3] as? String, "/tmp/project")
        XCTAssertEqual(values[4] as? String, "/tmp/ignored-project")
        XCTAssertEqual(values[5] as? Bool, true)
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
              document.querySelector('[data-filter="unread"]').click();
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
                recencyTimestampMilliseconds: 3,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "changed-project-thread-two",
                title: "Second changed project thread",
                preview: "Second",
                projectName: "Changed Project",
                projectPath: "/tmp/changed-project",
                recencyTimestampMilliseconds: 2
            ),
            ThreadSummary.fixture(
                id: "clean-project-thread",
                title: "Clean project thread",
                preview: "Clean",
                projectName: "Clean Project",
                projectPath: "/tmp/clean-project",
                recencyTimestampMilliseconds: 1
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
        XCTAssertEqual(values[1] as? String, "1 project has uncommitted changes: dirty")
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
              window.__codexDashboard.applySnapshot(\(payload));
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
              window.__codexDashboard.applySnapshot(\(payload));
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

    func testCommitCompatibilityProbeVerifiesFullControlPathAndRestoresUI() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <button type="button" aria-label="Toggle side panel">Panel</button>
              <script>
                document.documentElement.dataset.panelClicks = '0';
                document.documentElement.dataset.environmentClicks = '0';
                document.documentElement.dataset.commitClicks = '0';
                const panel = document.querySelector('[aria-label="Toggle side panel"]');
                panel.addEventListener('click', () => {
                  document.documentElement.dataset.panelClicks = String(
                    Number(document.documentElement.dataset.panelClicks) + 1
                  );
                  const existing = document.querySelector('[data-test-environment]');
                  if (existing) {
                    existing.remove();
                    document.querySelector('[data-test-native-commit]')?.remove();
                    return;
                  }
                  const environment = document.createElement('button');
                  environment.type = 'button';
                  environment.dataset.testEnvironment = '';
                  environment.textContent = 'Environment';
                  environment.setAttribute('aria-expanded', 'false');
                  environment.addEventListener('click', () => {
                    document.documentElement.dataset.environmentClicks = String(
                      Number(document.documentElement.dataset.environmentClicks) + 1
                    );
                    const expanded = environment.getAttribute('aria-expanded') === 'true';
                    environment.setAttribute('aria-expanded', String(!expanded));
                    if (expanded) {
                      document.querySelector('[data-test-native-commit]')?.remove();
                      return;
                    }
                    const commit = document.createElement('button');
                    commit.type = 'button';
                    commit.dataset.slot = 'thread-summary-panel-item-button';
                    commit.dataset.testNativeCommit = '';
                    commit.textContent = 'Commit or push';
                    commit.addEventListener('click', () => {
                      document.documentElement.dataset.commitClicks = String(
                        Number(document.documentElement.dataset.commitClicks) + 1
                      );
                    });
                    document.body.append(commit);
                  });
                  document.body.append(environment);
                });
              </script>
            </body></html>
            """
        )
        let contractSource = try DashboardInjectionResources.loadRendererContractSource()

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              \(contractSource)
              codexUIContracts.probeCommitOrPushControls(500).then((result) => {
                document.documentElement.dataset.probeResult = String(result);
              });
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.documentElement.dataset.probeResult !== undefined",
            in: webView
        )
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.documentElement.dataset.probeResult,
              document.documentElement.dataset.panelClicks,
              document.documentElement.dataset.environmentClicks,
              document.documentElement.dataset.commitClicks,
              Boolean(document.querySelector('[data-test-environment]')),
              Boolean(document.querySelector('[data-test-native-commit]')),
            ]
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(state) as? [AnyHashable], ["true", "2", "2", "0", false, false])
    }

    func testCommitCompatibilityProbeRejectsIncompleteControlPathAndRestoresUI() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <button type="button" aria-label="Toggle side panel">Panel</button>
              <script>
                document.documentElement.dataset.panelClicks = '0';
                const panel = document.querySelector('[aria-label="Toggle side panel"]');
                panel.addEventListener('click', () => {
                  document.documentElement.dataset.panelClicks = String(
                    Number(document.documentElement.dataset.panelClicks) + 1
                  );
                });
              </script>
            </body></html>
            """
        )
        let contractSource = try DashboardInjectionResources.loadRendererContractSource()

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              \(contractSource)
              codexUIContracts.probeCommitOrPushControls(100).then((result) => {
                document.documentElement.dataset.probeResult = String(result);
              });
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.documentElement.dataset.probeResult !== undefined",
            in: webView
        )
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.documentElement.dataset.probeResult,
              document.documentElement.dataset.panelClicks,
            ]
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(state) as? [AnyHashable], ["false", "2"])
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
                recencyTimestampMilliseconds: 5,
                runState: .running,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "off-sidebar-idle-thread",
                title: "Newest idle thread not mounted in the sidebar",
                projectPath: "/tmp/changed-project",
                recencyTimestampMilliseconds: 4,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "idle-thread",
                title: "Older idle thread",
                projectPath: "/tmp/changed-project",
                recencyTimestampMilliseconds: 2,
                workingTreeStatus: .hasChanges
            ),
            ThreadSummary.fixture(
                id: "clean-thread",
                title: "Clean project thread",
                projectPath: "/tmp/clean-project",
                recencyTimestampMilliseconds: 1,
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

    func testRunningFilterShowsOnlyRunningThreads() async throws {
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
                recencyTimestampMilliseconds: 4,
                runState: .running,
                workingTreeStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-running-two",
                title: "Second running thread",
                preview: "Running",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                recencyTimestampMilliseconds: 3,
                runState: .running,
                workingTreeStatus: .clean
            ),
            ThreadSummary.fixture(
                id: "project-a-idle",
                title: "Idle thread",
                preview: "Idle",
                projectName: "Project A",
                projectPath: "/tmp/project-a",
                recencyTimestampMilliseconds: 2
            ),
            ThreadSummary.fixture(
                id: "project-b-running",
                title: "Other running thread",
                preview: "Running",
                projectName: "Project B",
                projectPath: "/tmp/project-b",
                recencyTimestampMilliseconds: 1,
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
              document.querySelector('[data-filter="running"]').click();
              return [
                document.querySelector('[data-navigation-running-count]').textContent,
                document.querySelector('[data-navigation-running]').getAttribute('aria-label'),
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter="running"]').classList.contains('is-active'),
                document.querySelector('[data-filter="running"]').textContent.trim(),
                document.querySelector('[data-filter-count="running"]').textContent,
                document.querySelector('[data-dashboard-summary]').getAttribute('aria-label'),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "3")
        XCTAssertEqual(values[1] as? String, "3 running threads")
        XCTAssertEqual(
            values[2] as? [String],
            ["project-a-running-one", "project-a-running-two", "project-b-running"]
        )
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "Running 3")
        XCTAssertEqual(values[5] as? String, "3")
        XCTAssertEqual(values[6] as? String, "3 running, 0 unread, 0 changed projects")
    }

    func testAllFilterIsDefaultAndSearchesIdleCleanThreads() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "running", title: "Active work", runState: .running),
            .fixture(id: "idle", title: "Archived needle", runState: .idle),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const allIsActive = document.querySelector('[data-filter="all"]').classList.contains('is-active');
              const initialIDs = [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                .map((thread) => thread.dataset.threadId);
              const search = document.querySelector('[data-dashboard-search]');
              search.value = 'Archived needle';
              search.dispatchEvent(new Event('input', { bubbles: true }));
              document.querySelector('[data-filter="all"]').click();
              return [
                allIsActive,
                initialIDs,
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter-count="all"]').textContent,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? [String], ["running", "idle"])
        XCTAssertEqual(values[2] as? [String], ["idle"])
        XCTAssertEqual(values[3] as? String, "2")
    }

    func testRunningChangedProjectUsesConsistentCountAndDefersCommitAction() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
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
              window.__codexDashboard.applySnapshot(\(payload));
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

    func testThreadRowUsesNativeButtonAndOpensFromActivation() async throws {
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
        let thread = ThreadSummary.fixture(
            id: "thread-one",
            title: "Keyboard target",
            runState: .running
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const row = document.querySelector('[data-thread-list] .dashboard-thread');
              const contract = [row.tagName, row.type, row.getAttribute('aria-label')];
              row.click();
              window.__codexDashboard.open();
              document.querySelector('[data-thread-list] .dashboard-thread').click();
              return [contract, document.documentElement.dataset.openCount];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["BUTTON", "button", "Open thread: Keyboard target"])
        XCTAssertEqual(values[1] as? String, "2")
    }

    func testCompletedThreadShowsTickInsteadOfOpenArrow() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "completed",
                title: "Finished work",
                latestLifecycleEvent: ThreadLifecycleEvent(kind: .completed, timestamp: .now)
            ),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              const row = document.querySelector('[data-thread-id="completed"]');
              return [
                Boolean(row.querySelector('.dashboard-completed-status')),
                Boolean(row.querySelector('.dashboard-open-affordance')),
                row.querySelector('.dashboard-completed-status')?.getAttribute('aria-label'),
              ];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], [true, false, "Completed"])
    }

    func testCompletionRouteDoesNotReplaceOpenDashboard() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let expression = try XCTUnwrap(DashboardRendererScript.openThread("completed-thread"))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.documentElement.dataset.routeCount = '0';
              window.addEventListener('message', (event) => {
                if (event.data?.type === 'navigate-to-route') {
                  document.documentElement.dataset.routeCount = String(
                    Number(document.documentElement.dataset.routeCount) + 1
                  );
                }
              });
              window.__codexDashboard.open();
              \(expression);
              return [
                document.documentElement.dataset.routeCount,
                window.__codexDashboard.isOpen(),
              ];
            })()
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(result) as? [AnyHashable], ["0", true])
    }

    func testAccountSelectorPublishesSwitchAction() async throws {
        let webView = try await DashboardWebTestHarness.threadDashboardWebView()
        let personalID = UUID()
        let workID = UUID()
        let snapshot = DashboardSnapshotPayload(
            threads: [],
            accounts: [
                DashboardAccountPayload(
                    id: personalID.uuidString, name: "Personal", isActive: true
                ),
                DashboardAccountPayload(id: workID.uuidString, name: "Work", isActive: false),
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
        XCTAssertEqual(action["profileID"], workID.uuidString)
    }

}
