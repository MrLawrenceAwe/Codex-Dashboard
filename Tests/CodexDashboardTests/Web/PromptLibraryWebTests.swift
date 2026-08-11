import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class PromptLibraryWebTests: SerializedDashboardWebTestCase {
    func testUnrelatedHostMutationsDoNotRescanComposerSelectors() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const original = document.querySelectorAll.bind(document);
              document.documentElement.dataset.querySelectorAllCount = '0';
              document.querySelectorAll = (...arguments) => {
                document.documentElement.dataset.querySelectorAllCount = String(
                  Number(document.documentElement.dataset.querySelectorAllCount) + 1
                );
                return original(...arguments);
              };
              const unrelated = document.createElement('span');
              unrelated.textContent = 'Streaming response token';
              document.querySelector('main').append(unrelated);
            })()
            """
        )

        try await Task.sleep(for: .milliseconds(100))
        let scanCount = try await webView.evaluateJavaScript(
            "document.documentElement.dataset.querySelectorAllCount"
        ) as? String
        XCTAssertEqual(scanCount, "0")
    }

    func testSavedPromptCanBeCreatedAndInsertedIntoSupportedComposers() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let textareaResult = try await webView.evaluateJavaScript(
            """
            (() => {
              const launcher = document.querySelector('[data-codex-prompt-launcher]');
              const composer = document.querySelector('textarea[placeholder="Do anything"]');
              launcher.click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Review code';
              document.querySelector('[name="section"]').value = 'Code review';
              document.querySelector('[name="content"]').value = 'Review this code for correctness issues.\\n\\nReturn only actionable findings.';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const savedPromptButton = document.querySelector('[data-prompt-use]');
              const savedPromptName = savedPromptButton.querySelector('strong').textContent;
              const savedPromptID = savedPromptButton.dataset.promptUse;
              document.querySelector('[data-prompt-use]').click();
              const textareaValue = document.querySelector('textarea[placeholder="Do anything"]').value;
              return JSON.stringify({ launcherLabel: launcher.textContent.trim(), savedPromptName, textareaValue });
            })()
            """
        ) as? String
        let textareaValues = try decodeJSONObject(try XCTUnwrap(textareaResult))

        let richTextWebView = try await DashboardWebTestHarness.promptLibraryWebView(
            includeContentEditableComposer: true
        )

        let richTextResult = try await richTextWebView.evaluateJavaScript(
            """
            (() => {
              const launcher = document.querySelector('[data-codex-prompt-launcher]');
              const contentEditable = document.querySelector('[contenteditable="true"]');
              contentEditable.classList.add('ProseMirror');
              contentEditable.textContent = 'Existing content';
              let pasteCount = 0;
              class FakeSlice {
                constructor(content) { this.content = content; }
              }
              const transaction = {
                replaceSelection(slice) {
                  this.slice = slice;
                  return this;
                },
                scrollIntoView() { return this; },
              };
              const editorView = {
                dom: contentEditable,
                focus: () => contentEditable.focus(),
                state: {
                  schema: {
                    text: (text) => ({ text }),
                    nodes: {
                      paragraph: { create: (_, child) => ({ text: child?.text || '' }) },
                      doc: { create: (_, paragraphs) => ({ content: paragraphs }) },
                    },
                  },
                  doc: { slice: () => new FakeSlice([]) },
                  tr: transaction,
                },
                dispatch: ({ slice }) => {
                  pasteCount += 1;
                  contentEditable.textContent += `\\n${slice.content.map((paragraph) => paragraph.text).join('\\n')}`;
                },
              };
              contentEditable.parentElement.__reactFiber$test = {
                pendingProps: {},
                return: {
                  pendingProps: { composerController: { view: editorView } },
                  return: null,
                },
              };
              launcher.click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Review code';
              document.querySelector('[name="section"]').value = 'Code review';
              document.querySelector('[name="content"]').value = 'Review this code for correctness issues.\\n\\nReturn only actionable findings.';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const savedPromptID = document.querySelector('[data-prompt-use]').dataset.promptUse;
              document.querySelector('[data-prompt-use]').click();
              const insertedContent = contentEditable.textContent;
              const foreignDialog = document.createElement('div');
              foreignDialog.id = 'codex-dashboard-prompt-library-dialog';
              foreignDialog.innerHTML = `<button data-prompt-use="${savedPromptID}">Foreign prompt</button>`;
              document.body.append(foreignDialog);
              foreignDialog.querySelector('button').click();
              const foreignDialogIgnored = contentEditable.textContent === insertedContent;
              foreignDialog.remove();
              return JSON.stringify({
                contentEditableValue: document.querySelector('[contenteditable="true"]').textContent,
                pasteCount,
                foreignDialogIgnored,
                closedAfterInsertion: !document.getElementById('codex-dashboard-prompt-library-dialog'),
              });
            })()
            """
        ) as? String
        let richTextValues = try decodeJSONObject(try XCTUnwrap(richTextResult))
        XCTAssertEqual(textareaValues["launcherLabel"] as? String, "Prompts")
        XCTAssertEqual(textareaValues["savedPromptName"] as? String, "Review code")
        XCTAssertEqual(
            textareaValues["textareaValue"] as? String,
            "Review this code for correctness issues.\n\nReturn only actionable findings."
        )
        XCTAssertEqual(
            richTextValues["contentEditableValue"] as? String,
            "Existing content\n\nReview this code for correctness issues.\n\nReturn only actionable findings."
        )
        XCTAssertEqual(richTextValues["pasteCount"] as? Int, 1)
        XCTAssertEqual(richTextValues["foreignDialogIgnored"] as? Bool, true)
        XCTAssertEqual(richTextValues["closedAfterInsertion"] as? Bool, true)
    }

    private func decodeJSONObject(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

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
              const exportButton = document.querySelector('[data-prompt-export]');
              return {
                names: [...document.querySelectorAll('[data-prompt-use] strong')].map((item) => item.textContent),
                hasExport: Boolean(exportButton),
                hasImport: Boolean(document.querySelector('[data-prompt-import-file][accept*="json"]')),
                searchPlaceholder: renderedSearch.getAttribute('placeholder'),
                headerSubtitle: document.querySelector('.dashboard-prompt-header p')?.textContent || null,
                searchHeight: getComputedStyle(renderedSearch).height,
                searchFontSize: getComputedStyle(renderedSearch).fontSize,
                exportHeight: getComputedStyle(exportButton).height,
                exportFontSize: getComputedStyle(exportButton).fontSize,
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["names"] as? [String], ["Review code"])
        XCTAssertEqual(values["hasExport"] as? Bool, true)
        XCTAssertEqual(values["hasImport"] as? Bool, true)
        XCTAssertNil(values["searchPlaceholder"] as? String)
        XCTAssertNil(values["headerSubtitle"] as? String)
        XCTAssertEqual(values["searchHeight"] as? String, "32px")
        XCTAssertEqual(values["searchFontSize"] as? String, "12px")
        XCTAssertEqual(values["exportHeight"] as? String, "32px")
        XCTAssertEqual(values["exportFontSize"] as? String, "11px")
    }

    func testPromptLauncherIsAdjacentToAddAndRemovedOnDestroy() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const addButton = document.querySelector('button[aria-label="Add"]');
              const launcher = document.querySelector('[data-codex-prompt-launcher]');
              const adjacentToAdd = addButton.nextElementSibling === launcher;
              const accessibleName = launcher.getAttribute('aria-label');
              window.__codexDashboard.destroy();
              return {
                adjacentToAdd,
                accessibleName,
                removedOnDestroy: !document.querySelector('[data-codex-prompt-launcher]'),
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["adjacentToAdd"] as? Bool, true)
        XCTAssertEqual(values["accessibleName"] as? String, "Prompts")
        XCTAssertEqual(values["removedOnDestroy"] as? Bool, true)
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
        _ = try await webView.evaluateJavaScript(
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
              window.__codexDashboard.destroy();
            })()
            """
        )

        let injection = try DashboardInjectionPayload.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let sectionSurvived = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
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
              document.querySelector('[data-codex-prompt-launcher]').click();
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
              const launcher = document.querySelector('[data-codex-prompt-launcher]');
              launcher.focus();
              launcher.click();
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
              const escapeClosedFromOutside = !document.getElementById('codex-dashboard-prompt-library-dialog');

              launcher.click();
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

    func testInvalidPromptImportPreservesExistingLibrary() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Keep me';
              document.querySelector('[name="content"]').value = 'Existing prompt';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              window.__promptLibraryBeforeInvalidImport = localStorage.getItem('codex-dashboard.prompt-library');
              const input = document.querySelector('[data-prompt-import-file]');
              const transfer = new DataTransfer();
              transfer.items.add(new File(['{}'], 'unrelated.json', { type: 'application/json' }));
              input.files = transfer.files;
              input.dispatchEvent(new Event('change', { bubbles: true }));
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-prompt-storage-error]')?.hidden === false",
            in: webView
        )
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              return [
                localStorage.getItem('codex-dashboard.prompt-library') === window.__promptLibraryBeforeInvalidImport,
                document.querySelectorAll('[data-prompt-use]').length,
                document.querySelector('[data-prompt-storage-error]').textContent,
                !document.querySelector('[data-prompt-storage-error]').hidden,
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Int, 1)
        XCTAssertTrue((values[2] as? String)?.contains("Could not import") == true)
        XCTAssertEqual(values[3] as? Bool, true)
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
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.prompt-library'));
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

    func testSelectionPlaceholderUsesTextareaSelectionCapturedBeforeDialogOpens() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const composer = document.querySelector('textarea[placeholder="Do anything"]');
              composer.value = 'alpha beta gamma';
              composer.focus();
              composer.setSelectionRange(6, 10);
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Use selection';
              document.querySelector('[name="content"]').value = 'Selected: {{selection}}';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-use]').click();
              return composer.value;
            })()
            """
        ) as? String

        XCTAssertEqual(result, "alpha Selected: beta gamma")
    }

}
