import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardInjectionTests: XCTestCase {
    func testDashboardMountsFiltersNavigatesAndDestroys() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html>
              <head><meta charset="utf-8"></head>
              <body>
                <div class="mock-app">
                  <aside class="app-shell-left-panel" role="navigation">
                    <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-read">Read thread</button>
                    <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-unread">Unread thread</button>
                  </aside>
                  <main>Conversation surface</main>
                </div>
              </body>
            </html>
            """,
            baseURL: nil
        )
        try await waitUntilLoaded(webView)
        let injection = try DashboardInjection.load()
        let mounted = try await webView.evaluateJavaScript(injection.mountExpression) as? Bool
        XCTAssertEqual(mounted, true)
        let healthy = try await webView.evaluateJavaScript(injection.healthCheckExpression) as? Bool
        XCTAssertEqual(healthy, true)

        let threads = [
            DashboardThread(
                id: "thread-read",
                title: "Read thread",
                preview: "Already read",
                workspaceName: "Project",
                workspacePath: "/tmp/project",
                recencyTimestamp: 2,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .clean
            ),
            DashboardThread(
                id: "thread-unread",
                title: "Unread thread",
                preview: "Needs attention",
                workspaceName: "Project",
                workspacePath: "/tmp/project",
                recencyTimestamp: 1,
                isPinned: true,
                model: "test-model",
                activity: .running,
                gitWorkingTreeStatus: .hasChanges
            ),
        ]
        let payloadData = try JSONEncoder().encode(DashboardPayload(threads: threads))
        let payload = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const unreadRow = document.querySelector('[data-app-action-sidebar-thread-id="local:thread-unread"]');
              unreadRow.__reactFiber$test = {
                memoizedProps: { conversationId: 'thread-unread', isUnread: true },
                return: null,
              };
              unreadRow.addEventListener('click', () => { window.__openedThreadID = 'thread-unread'; });
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
              const visibleThreads = document.querySelectorAll('[data-thread-list] .dashboard-thread');
              visibleThreads[0].querySelector('[data-open-thread]').click();
              return [
                Boolean(document.getElementById('codex-dashboard-navigation')),
                visibleThreads.length,
                visibleThreads[0].dataset.threadId,
                document.documentElement.classList.contains('codex-dashboard-open'),
                window.__openedThreadID,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Int, 1)
        XCTAssertEqual(values[2] as? String, "thread-unread")
        XCTAssertEqual(values[3] as? Bool, false)
        XCTAssertEqual(values[4] as? String, "thread-unread")

        let destroyed = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.destroy();
              return typeof window.__codexDashboard === 'undefined'
                && !document.getElementById('codex-dashboard-page')
                && !document.getElementById('codex-dashboard-navigation');
            })()
            """
        ) as? Bool
        XCTAssertEqual(destroyed, true)
    }

    func testUncommittedFilterIncludesEveryThreadFromProjectsWithChanges() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"></aside><main>Conversation surface</main>
            </body></html>
            """,
            baseURL: nil
        )
        try await waitUntilLoaded(webView)
        let injection = try DashboardInjection.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let threads = [
            DashboardThread(
                id: "changed-project-thread-one",
                title: "First changed project thread",
                preview: "First",
                workspaceName: "Changed Project",
                workspacePath: "/tmp/changed-project",
                recencyTimestamp: 3,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .hasChanges
            ),
            DashboardThread(
                id: "changed-project-thread-two",
                title: "Second changed project thread",
                preview: "Second",
                workspaceName: "Changed Project",
                workspacePath: "/tmp/changed-project",
                recencyTimestamp: 2,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .clean
            ),
            DashboardThread(
                id: "clean-project-thread",
                title: "Clean project thread",
                preview: "Clean",
                workspaceName: "Clean Project",
                workspacePath: "/tmp/clean-project",
                recencyTimestamp: 1,
                isPinned: false,
                model: nil,
                activity: .idle,
                gitWorkingTreeStatus: .clean
            ),
        ]
        let payloadData = try JSONEncoder().encode(DashboardPayload(threads: threads))
        let payload = try XCTUnwrap(String(data: payloadData, encoding: .utf8))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(payload));
              window.__codexDashboard.open();
              document.querySelector('[data-filter="uncommitted"]').click();
              return [
                [...document.querySelectorAll('[data-thread-list] .dashboard-thread')]
                  .map((thread) => thread.dataset.threadId),
                document.querySelector('[data-filter-count="uncommitted"]').textContent,
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
    }

    func testSavedPromptsCanBeCreatedAndInsertedIntoComposer() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>
                <div data-composer-overlay-floating-ui="true" aria-label="Add">
                  <button role="menuitem" data-list-navigation-item="true" class="opacity-75 bg-token-list-hover-background opacity-100"><span>Record a skill</span></button>
                </div>
                <textarea placeholder="Do anything"></textarea>
                <div contenteditable="true" role="textbox"></div>
              </main>
            </body></html>
            """,
            baseURL: nil
        )
        try await waitUntilLoaded(webView)
        _ = try? await webView.evaluateJavaScript("try { localStorage.clear(); true } catch (_) { false }")

        let injection = try DashboardInjection.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const promptMenuItem = document.querySelector('[data-codex-prompt-menu-item]');
              promptMenuItem.dispatchEvent(new PointerEvent('pointerenter'));
              const promptTookHighlight = promptMenuItem.classList.contains('opacity-100')
                && promptMenuItem.classList.contains('bg-token-list-hover-background')
                && !document.querySelector('[data-list-navigation-item]:not([data-codex-prompt-menu-item])').classList.contains('opacity-100');
              promptMenuItem.dispatchEvent(new PointerEvent('pointerdown', {
                bubbles: true,
                cancelable: true,
              }));
              document.querySelector('[data-prompt-new-section]').click();
              document.querySelector('[name="sectionName"]').value = 'Research';
              document.querySelector('[data-prompt-section-form] button[type="submit"]').click();
              const emptySectionWasCreated = Boolean(
                document.querySelector('[data-prompt-section="Research"]')
              ) && document.querySelector('[data-prompt-section="Research"] .dashboard-prompt-section-count').textContent === '0';
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Review code';
              document.querySelector('[name="section"]').value = 'Code review';
              document.querySelector('[name="content"]').value = 'Review this code for correctness issues.';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const sectionToggle = document.querySelector('[data-prompt-section-toggle]');
              sectionToggle.click();
              const collapsedSectionToggle = document.querySelector('[data-prompt-section-toggle]');
              const sectionCollapsed = collapsedSectionToggle.getAttribute('aria-expanded') === 'false'
                && document.querySelector('.dashboard-prompt-section-body').hidden;
              collapsedSectionToggle.click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Explain code';
              document.querySelector('[name="section"]').value = 'Writing';
              document.querySelector('[name="content"]').value = 'Explain this code clearly.';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const dragTransfer = {
                effectAllowed: '',
                dropEffect: '',
                setData() {},
              };
              const dispatchDrag = (element, type) => {
                const event = new Event(type, { bubbles: true, cancelable: true });
                Object.defineProperty(event, 'dataTransfer', { value: dragTransfer });
                Object.defineProperty(event, 'clientY', { value: 0 });
                element.dispatchEvent(event);
              };
              const explainRow = [...document.querySelectorAll('[data-prompt-row-id]')]
                .find((row) => row.textContent.includes('Explain code'));
              dispatchDrag(explainRow, 'dragstart');
              const codeReviewSection = document.querySelector('[data-prompt-section="Code review"]');
              dispatchDrag(codeReviewSection.querySelector('[data-prompt-section-toggle]'), 'dragover');
              dispatchDrag(codeReviewSection.querySelector('[data-prompt-section-toggle]'), 'drop');
              const dragMovedPromptAcrossSections = document.querySelectorAll('[data-prompt-section]').length === 3
                && document.querySelector('[data-prompt-section="Writing"] .dashboard-prompt-section-count').textContent === '0'
                && document.querySelector('[data-prompt-section="Code review"] .dashboard-prompt-section-count').textContent === '2'
                && [...document.querySelectorAll('[data-prompt-section="Code review"] [data-prompt-use] strong')]
                  .map((element) => element.textContent).join(',') === 'Review code,Explain code';
              const savedPromptName = document.querySelector('[data-prompt-use] strong').textContent;
              document.querySelector('[data-prompt-use]').click();
              const textareaValue = document.querySelector('textarea[placeholder="Do anything"]').value;
              document.querySelector('textarea[placeholder="Do anything"]').remove();
              promptMenuItem.click();
              document.querySelector('[data-prompt-use]').click();
              const promptLibraryClosedAfterInsertion = !document.getElementById('codex-dashboard-prompt-dialog');
              promptMenuItem.click();
              const deleteButton = document.querySelector('[data-prompt-delete]');
              deleteButton.click();
              const promptSurvivedFirstDeleteClick = Boolean(document.querySelector('[data-prompt-use]'));
              const deleteRequiresConfirmation = deleteButton.textContent === 'Confirm delete';
              deleteButton.click();
              const promptWasDeleted = ![...document.querySelectorAll('[data-prompt-use] strong')]
                .some((element) => element.textContent === 'Review code');
              return [
                promptMenuItem.textContent.trim(),
                savedPromptName,
                textareaValue,
                promptLibraryClosedAfterInsertion,
                promptMenuItem.parentElement.getAttribute('data-composer-overlay-floating-ui'),
                document.querySelector('[contenteditable="true"]').textContent,
                promptTookHighlight,
                promptSurvivedFirstDeleteClick,
                deleteRequiresConfirmation,
                promptWasDeleted,
                sectionCollapsed,
                sectionToggle.textContent.includes('Code review'),
                dragMovedPromptAcrossSections,
                emptySectionWasCreated,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Prompts")
        XCTAssertEqual(values[1] as? String, "Review code")
        XCTAssertEqual(values[2] as? String, "Review this code for correctness issues.")
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "true")
        XCTAssertEqual(values[5] as? String, "Review this code for correctness issues.")
        XCTAssertEqual(values[6] as? Bool, true)
        XCTAssertEqual(values[7] as? Bool, true)
        XCTAssertEqual(values[8] as? Bool, true)
        XCTAssertEqual(values[9] as? Bool, true)
        XCTAssertEqual(values[10] as? Bool, true)
        XCTAssertEqual(values[11] as? Bool, true)
        XCTAssertEqual(values[12] as? Bool, true)
        XCTAssertEqual(values[13] as? Bool, true)

        let removedOnDestroy = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.destroy();
              return !document.querySelector('[data-codex-prompt-menu-item]');
            })()
            """
        ) as? Bool
        XCTAssertEqual(removedOnDestroy, true)
    }

    func testPromptLibraryCreatesEmptySectionsAndScrollsLongLists() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>
                <div data-composer-overlay-floating-ui="true" aria-label="Add">
                  <button data-list-navigation-item="true"><span>Record a skill</span></button>
                </div>
                <textarea placeholder="Do anything"></textarea>
              </main>
            </body></html>
            """,
            baseURL: nil
        )
        try await waitUntilLoaded(webView)
        _ = try? await webView.evaluateJavaScript("try { localStorage.clear(); true } catch (_) { false }")

        let injection = try DashboardInjection.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-menu-item]').click();
              for (let index = 1; index <= 14; index += 1) {
                document.querySelector('[data-prompt-new-section]').click();
                document.querySelector('[name="sectionName"]').value = `Section ${index}`;
                document.querySelector('[data-prompt-section-form] button[type="submit"]').click();
              }
              const panel = document.querySelector('.dashboard-prompt-panel');
              panel.style.height = '220px';
              const content = document.querySelector('[data-prompt-content]');
              document.querySelector('[data-prompt-section="Section 14"] [data-prompt-section-toggle]').click();
              return [
                document.querySelectorAll('[data-prompt-section]').length,
                content.scrollHeight > content.clientHeight,
                getComputedStyle(content).overflowY,
                document.querySelector('[data-prompt-section="Section 14"] .dashboard-prompt-section-count').textContent,
                document.querySelector('[data-prompt-section="Section 14"] .dashboard-prompt-section-body').hidden,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 14)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? String, "auto")
        XCTAssertEqual(values[3] as? String, "0")
        XCTAssertEqual(values[4] as? Bool, true)
    }

    private func waitUntilLoaded(_ webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while webView.isLoading {
            guard ContinuousClock.now < deadline else {
                throw DashboardError.invalidDevToolsResponse
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
