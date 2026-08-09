import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class PromptLibraryWebTests: SerializedDashboardWebTestCase {
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
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test")
        )
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        _ = try? await webView.evaluateJavaScript("try { localStorage.clear(); true } catch (_) { false }")

        let injection = try DashboardInjection.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const composer = document.querySelector('textarea[placeholder="Do anything"]');
              composer.addEventListener('input', (event) => {
                if (event.data) composer.value += event.data;
              });
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
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test")
        )
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
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

    func testPromptStorageFailureAndDialogKeyboardBehavior() async throws {
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
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test")
        )
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        _ = try? await webView.evaluateJavaScript("try { localStorage.clear(); true } catch (_) { false }")
        let injection = try DashboardInjection.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const menuItem = document.querySelector('[data-codex-prompt-menu-item]');
              menuItem.focus();
              menuItem.click();
              const lastButton = document.querySelector('[data-prompt-new-section]');
              lastButton.focus();
              lastButton.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Tab', bubbles: true, cancelable: true,
              }));
              const tabWrapped = document.activeElement.matches('[data-prompt-close]');

              document.querySelector('textarea[placeholder="Do anything"]').focus();
              document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Escape', bubbles: true, cancelable: true,
              }));
              const escapeClosedFromOutside = !document.getElementById('codex-dashboard-prompt-dialog');

              menuItem.click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Unsaved prompt';
              document.querySelector('[name="content"]').value = 'This must not appear as saved.';
              const originalSetItem = Storage.prototype.setItem;
              Storage.prototype.setItem = function setItem() { throw new Error('storage unavailable'); };
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              Storage.prototype.setItem = originalSetItem;
              return [
                tabWrapped,
                escapeClosedFromOutside,
                Boolean(document.querySelector('[data-prompt-form]')),
                !document.querySelector('[data-prompt-storage-error]').hidden,
                !document.querySelector('[data-prompt-use]'),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? Bool, true)
    }

}
