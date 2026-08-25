import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension PromptLibraryWebTests {
    func testPromptSearchAndTransferControls() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              const createPrompt = (name, content) => {
                document.querySelector('[data-prompt-new]').click();
                document.querySelector('[name="name"]').value = name;
                document.querySelector('[name="content"]').value = content;
                document.querySelector('[data-prompt-form] button[type="submit"]').click();
              };
              createPrompt('Review code', 'Find correctness issues');
              createPrompt('Write summary', 'Summarise the discussion');
              const search = document.querySelector('[data-prompt-search]');
              search.value = 'review';
              search.dispatchEvent(new Event('input', { bubbles: true }));
              const renderedSearch = document.querySelector('[data-prompt-search]');
              const searchSelection = [renderedSearch.selectionStart, renderedSearch.selectionEnd];
              const filteredNames = [...document.querySelectorAll('[data-prompt-use] strong')].map((item) => item.textContent);
              const values = {
                filteredNames,
                searchSelection,
                hasTransferActions: Boolean(document.querySelector('[data-prompt-actions-toggle]')),
                searchPlaceholder: renderedSearch.getAttribute('placeholder'),
                headerSubtitle: document.querySelector('.dashboard-prompt-header p')?.textContent || null,
                searchHeight: getComputedStyle(renderedSearch).height,
                searchFontSize: getComputedStyle(renderedSearch).fontSize,
              };
              renderedSearch.value = '';
              renderedSearch.dispatchEvent(new Event('search', { bubbles: true }));
              values.namesAfterClear = [...document.querySelectorAll('[data-prompt-use] strong')].map((item) => item.textContent);
              return values;
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["filteredNames"] as? [String], ["Review code"])
        XCTAssertEqual(values["searchSelection"] as? [Int], [6, 6])
        XCTAssertEqual(values["namesAfterClear"] as? [String], ["Review code", "Write summary"])
        XCTAssertEqual(values["hasTransferActions"] as? Bool, false)
        XCTAssertNil(values["searchPlaceholder"] as? String)
        XCTAssertNil(values["headerSubtitle"] as? String)
        XCTAssertEqual(values["searchHeight"] as? String, "32px")
        XCTAssertEqual(values["searchFontSize"] as? String, "12px")
    }

    func testPromptDragDropAndDeletion() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
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
              document.querySelector('[data-codex-prompt-launcher]').click();
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
        let exportedLibrary = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Temporary';
              document.querySelector('[name="section"]').value = 'Keep me';
              document.querySelector('[name="content"]').value = 'Temporary prompt';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-delete]').click();
              document.querySelector('[data-prompt-delete-confirm]').click();
              const exported = window.__codexDashboard.exportPromptLibrary();
              window.__codexDashboard.destroy();
              return exported;
            })()
            """
        ) as? String

        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let library = try XCTUnwrap(exportedLibrary)
        let sectionSurvived = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyPromptLibrary(\(library));
              document.querySelector('[data-codex-prompt-launcher]').click();
              return Boolean(document.querySelector('[data-prompt-section="Keep me"]'));
            })()
            """
        ) as? Bool

        XCTAssertEqual(sectionSurvived, true)
    }

    func testRenamingSectionRejectsCaseInsensitiveDuplicate() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'General prompt';
              document.querySelector('[name="section"]').value = 'General';
              document.querySelector('[name="content"]').value = 'Keep General canonical';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-new-section]').click();
              document.querySelector('[name="sectionName"]').value = 'Code review';
              document.querySelector('[data-prompt-section-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-section-rename="Code review"]').click();
              document.querySelector('[name="sectionName"]').value = 'general';
              document.querySelector('[data-prompt-section-rename-form] button[type="submit"]').click();
              const hasError = !document.querySelector('[data-prompt-storage-error]').hidden;
              document.querySelector('[data-prompt-cancel]').click();
              return {
                hasError,
                general: Boolean(document.querySelector('[data-prompt-section="General"]')),
                codeReview: Boolean(document.querySelector('[data-prompt-section="Code review"]')),
                storedSections: JSON.parse(window.__codexDashboard.exportPromptLibrary()).sections,
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)

        XCTAssertEqual(values["hasError"] as? Bool, true)
        XCTAssertEqual(values["general"] as? Bool, true)
        XCTAssertEqual(values["codeReview"] as? Bool, true)
        XCTAssertEqual(values["storedSections"] as? [String], ["General", "Code review"])
    }

    func testPromptKeyboardReorderingAndSectionManagementPreservePrompts() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new-section]').click();
              document.querySelector('[name="sectionName"]').value = 'Ops';
              document.querySelector('[data-prompt-section-form] button[type="submit"]').click();
              for (const [name, content] of [['First', 'One'], ['Second', 'Two']]) {
                document.querySelector('[data-prompt-new]').click();
                document.querySelector('[name="name"]').value = name;
                document.querySelector('[name="section"]').value = 'Ops';
                document.querySelector('[name="content"]').value = content;
                document.querySelector('[data-prompt-form] button[type="submit"]').click();
              }
              document.querySelector('[data-prompt-row-id]:last-child [data-prompt-move-up]').click();
              const orderAfterMove = [...document.querySelectorAll('[data-prompt-use] strong')]
                .map((element) => element.textContent);
              document.querySelector('[data-prompt-section-rename="Ops"]').click();
              document.querySelector('[name="sectionName"]').value = 'Operations';
              document.querySelector('[data-prompt-section-rename-form] button[type="submit"]').click();
              const deleteButton = document.querySelector('[data-prompt-section-delete="Operations"]');
              deleteButton.click();
              deleteButton.click();
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              return [
                orderAfterMove.join(','),
                stored.prompts.map((prompt) => prompt.name).join(','),
                stored.prompts.every((prompt) => prompt.section === 'General'),
                !stored.sections.includes('Operations'),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Second,First")
        XCTAssertEqual(values[1] as? String, "Second,First")
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
    }

}
