import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class PromptLibraryWebTests: SerializedDashboardWebTestCase {
    func testSavedPromptCanBeCreatedAndInsertedIntoSupportedComposers() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView(
            includeContentEditableComposer: true
        )
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const composer = document.querySelector('textarea[placeholder="Do anything"]');
              composer.addEventListener('input', (event) => {
                if (event.data) composer.value += event.data;
              });
              const menuItem = document.querySelector('[data-codex-prompt-menu-item]');
              menuItem.dispatchEvent(new PointerEvent('pointerdown', {
                bubbles: true,
                cancelable: true,
              }));
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Review code';
              document.querySelector('[name="section"]').value = 'Code review';
              document.querySelector('[name="content"]').value = 'Review this code for correctness issues.';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const savedPromptName = document.querySelector('[data-prompt-use] strong').textContent;
              document.querySelector('[data-prompt-use]').click();
              const textareaValue = document.querySelector('textarea[placeholder="Do anything"]').value;
              document.querySelector('textarea[placeholder="Do anything"]').remove();
              menuItem.click();
              document.querySelector('[data-prompt-use]').click();
              return {
                menuLabel: menuItem.textContent.trim(),
                savedPromptName,
                textareaValue,
                contentEditableValue: document.querySelector('[contenteditable="true"]').textContent,
                closedAfterInsertion: !document.getElementById('codex-dashboard-prompt-dialog'),
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["menuLabel"] as? String, "Prompts")
        XCTAssertEqual(values["savedPromptName"] as? String, "Review code")
        XCTAssertEqual(values["textareaValue"] as? String, "Review this code for correctness issues.")
        XCTAssertEqual(values["contentEditableValue"] as? String, "Review this code for correctness issues.")
        XCTAssertEqual(values["closedAfterInsertion"] as? Bool, true)
    }

    func testPromptMenuHighlightAndDestroyLifecycle() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const menuItem = document.querySelector('[data-codex-prompt-menu-item]');
              menuItem.dispatchEvent(new PointerEvent('pointerenter'));
              const highlighted = menuItem.classList.contains('opacity-100')
                && menuItem.classList.contains('bg-token-list-hover-background')
                && !document.querySelector('[data-list-navigation-item]:not([data-codex-prompt-menu-item])').classList.contains('opacity-100');
              window.__codexDashboard.destroy();
              return {
                highlighted,
                removedOnDestroy: !document.querySelector('[data-codex-prompt-menu-item]'),
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["highlighted"] as? Bool, true)
        XCTAssertEqual(values["removedOnDestroy"] as? Bool, true)
    }

    func testPromptDragDropAndDeletion() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-menu-item]').click();
              document.querySelector('[data-prompt-new-section]').click();
              document.querySelector('[name="sectionName"]').value = 'Research';
              document.querySelector('[data-prompt-section-form] button[type="submit"]').click();
              const createPrompt = (name, section) => {
                document.querySelector('[data-prompt-new]').click();
                document.querySelector('[name="name"]').value = name;
                document.querySelector('[name="section"]').value = section;
                document.querySelector('[name="content"]').value = `${name} content`;
                document.querySelector('[data-prompt-form] button[type="submit"]').click();
              };
              createPrompt('Review code', 'Code review');
              createPrompt('Explain code', 'Writing');
              const transfer = { effectAllowed: '', dropEffect: '', setData() {} };
              const drag = (element, type) => {
                const event = new Event(type, { bubbles: true, cancelable: true });
                Object.defineProperty(event, 'dataTransfer', { value: transfer });
                Object.defineProperty(event, 'clientY', { value: 0 });
                element.dispatchEvent(event);
              };
              const explainRow = [...document.querySelectorAll('[data-prompt-row-id]')]
                .find((row) => row.textContent.includes('Explain code'));
              const destination = document.querySelector('[data-prompt-section="Code review"]');
              drag(explainRow, 'dragstart');
              drag(destination.querySelector('[data-prompt-section-toggle]'), 'dragover');
              drag(destination.querySelector('[data-prompt-section-toggle]'), 'drop');
              const updatedDestination = document.querySelector('[data-prompt-section="Code review"]');
              const names = [...updatedDestination.querySelectorAll('[data-prompt-use] strong')]
                .map((element) => element.textContent);
              const deleteButton = updatedDestination.querySelector('[data-prompt-delete]');
              deleteButton.click();
              const survivedFirstClick = Boolean(updatedDestination.querySelector('[data-prompt-use]'));
              const requiresConfirmation = deleteButton.textContent === 'Confirm delete';
              deleteButton.click();
              return {
                names,
                emptySourceSection: document.querySelector('[data-prompt-section="Writing"] .dashboard-prompt-section-count').textContent === '0',
                survivedFirstClick,
                requiresConfirmation,
                remainingPromptCount: document.querySelectorAll('[data-prompt-use]').length,
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["names"] as? [String], ["Review code", "Explain code"])
        XCTAssertEqual(values["emptySourceSection"] as? Bool, true)
        XCTAssertEqual(values["survivedFirstClick"] as? Bool, true)
        XCTAssertEqual(values["requiresConfirmation"] as? Bool, true)
        XCTAssertEqual(values["remainingPromptCount"] as? Int, 1)

    }

    func testPromptLibraryCreatesEmptySectionsAndScrollsLongLists() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
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

    func testPromptSectionSurvivesAfterItsLastPromptIsDeleted() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-menu-item]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Temporary';
              document.querySelector('[name="section"]').value = 'Keep me';
              document.querySelector('[name="content"]').value = 'Temporary prompt';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-delete]').click();
              document.querySelector('[data-prompt-delete-confirm]').click();
              window.__codexDashboard.destroy();
            })()
            """
        )

        let injection = try DashboardInjectionPayload.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let sectionSurvived = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-menu-item]').click();
              return Boolean(document.querySelector('[data-prompt-section="Keep me"]'));
            })()
            """
        ) as? Bool

        XCTAssertEqual(sectionSurvived, true)
    }

    func testLegacyPromptStorageMigratesWithoutDataLoss() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.destroy();
              localStorage.removeItem('codex-dashboard.prompt-library');
              localStorage.setItem('codex-dashboard.saved-prompts', JSON.stringify([{
                id: 'legacy-prompt',
                name: 'Legacy prompt',
                content: 'Preserve me',
                section: 'Legacy section',
              }]));
              localStorage.setItem('codex-dashboard.prompt-sections', JSON.stringify(['Empty legacy section']));
            })()
            """
        )

        let injection = try DashboardInjectionPayload.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let migrated = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-menu-item]').click();
              const state = JSON.parse(localStorage.getItem('codex-dashboard.prompt-library'));
              return [
                document.querySelector('[data-prompt-use] strong').textContent,
                Boolean(document.querySelector('[data-prompt-section="Empty legacy section"]')),
                state.prompts.length,
                state.sections.length,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(migrated)
        XCTAssertEqual(values[0] as? String, "Legacy prompt")
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Int, 1)
        XCTAssertEqual(values[3] as? Int, 2)
    }

    func testPromptStorageFailureAndDialogKeyboardBehavior() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()

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
