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
              const originalElementQuery = Element.prototype.querySelector;
              document.documentElement.dataset.querySelectorAllCount = '0';
              document.documentElement.dataset.elementQuerySelectorCount = '0';
              document.querySelectorAll = (...arguments) => {
                document.documentElement.dataset.querySelectorAllCount = String(
                  Number(document.documentElement.dataset.querySelectorAllCount) + 1
                );
                return original(...arguments);
              };
              Element.prototype.querySelector = function (...arguments) {
                document.documentElement.dataset.elementQuerySelectorCount = String(
                  Number(document.documentElement.dataset.elementQuerySelectorCount) + 1
                );
                return originalElementQuery.apply(this, arguments);
              };
              const unrelated = document.createElement('span');
              unrelated.textContent = 'Streaming response token';
              document.querySelector('main').append(unrelated);
            })()
            """
        )

        try await Task.sleep(for: .milliseconds(100))
        let scanCount = try await webView.evaluateJavaScript(
            "[document.documentElement.dataset.querySelectorAllCount, document.documentElement.dataset.elementQuerySelectorCount]"
        ) as? [String]
        XCTAssertEqual(scanCount, ["0", "0"])
    }

    func testComposerObserverRestoresRemovedLauncher() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').remove();
            })()
            """
        )

        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(document.querySelector('[data-codex-prompt-launcher]'))",
            in: webView
        )
    }

    func testPromptLauncherMountsWhenNewChatComposerAppearsAfterNavigation() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('.composer-shell').remove();
              window.setTimeout(() => {
                const shell = document.createElement('div');
                shell.className = 'composer-shell';
                shell.innerHTML = `
                  <textarea placeholder="Do anything"></textarea>
                  <div class="composer-toolbar">
                    <button type="button" aria-label="Add">+</button>
                  </div>`;
                document.querySelector('main').append(shell);
              }, 50);
            })()
            """
        )

        try await DashboardWebTestHarness.waitForJavaScript(
            """
            (() => {
              const addButton = document.querySelector('button[aria-label="Add"]');
              const launcher = document.querySelector('[data-codex-prompt-launcher]');
              return Boolean(addButton && addButton.nextElementSibling === launcher);
            })()
            """,
            in: webView
        )
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

    func testProjectPromptsAreScopedToActiveComposerProjectAlongsideGlobals() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let snapshot = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "project-a-thread",
                projectName: "Project A",
                projectPath: "/tmp/project-a"
            ),
            .fixture(
                id: "project-b-thread",
                projectName: "Project B",
                projectPath: "/tmp/project-b"
            ),
        ])
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applySnapshot(\(snapshot));
              const composerShell = document.querySelector('.composer-shell');
              const activeThreadProps = { conversationId: 'project-a-thread' };
              composerShell.__reactFiber$test = { memoizedProps: activeThreadProps, return: null };
              const launcher = document.querySelector('[data-codex-prompt-launcher]');
              const createPrompt = (name, scope) => {
                document.querySelector('[data-prompt-new]').click();
                document.querySelector('[name="name"]').value = name;
                document.querySelector('[name="content"]').value = `${name} content`;
                document.querySelector('[name="scope"]').value = scope;
                document.querySelector('[data-prompt-form] button[type="submit"]').click();
              };

              launcher.click();
              createPrompt('Project A prompt', 'project');
              createPrompt('Global prompt', 'global');
              const projectAHeadings = [...document.querySelectorAll('.dashboard-prompt-scope > h3')]
                .map((heading) => heading.textContent);
              const projectANames = [...document.querySelectorAll('[data-prompt-use] strong')]
                .map((name) => name.textContent);
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());

              document.querySelector('.dashboard-prompt-icon-button').click();
              activeThreadProps.conversationId = 'project-b-thread';
              launcher.click();
              const projectBHeadings = [...document.querySelectorAll('.dashboard-prompt-scope > h3')]
                .map((heading) => heading.textContent);
              const projectBNames = [...document.querySelectorAll('[data-prompt-use] strong')]
                .map((name) => name.textContent);
              return JSON.stringify({
                projectAHeadings,
                projectANames,
                projectBHeadings,
                projectBNames,
                version: stored.version,
                scopes: stored.prompts.map((prompt) => prompt.scope),
              });
            })()
            """
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))

        XCTAssertEqual(values["projectAHeadings"] as? [String], ["This project · Project A", "Global"])
        XCTAssertEqual(values["projectANames"] as? [String], ["Project A prompt", "Global prompt"])
        XCTAssertEqual(values["projectBHeadings"] as? [String], ["This project · Project B", "Global"])
        XCTAssertEqual(values["projectBNames"] as? [String], ["Global prompt"])
        XCTAssertEqual(values["version"] as? Int, 3)
        XCTAssertEqual(
            values["scopes"] as? [[String: String]],
            [
                ["type": "project", "projectPath": "/tmp/project-a"],
                ["type": "global"],
            ]
        )
    }

    func testProjectPromptCanBeCreatedFromProjectNewChatBeforeThreadExists() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const projectID = 'project-a-id';
              const projectRow = document.createElement('div');
              projectRow.dataset.appActionSidebarProjectId = projectID;
              projectRow.__reactFiber$test = {
                memoizedProps: {},
                return: {
                  memoizedProps: {
                    group: {
                      projectId: projectID,
                      projectKind: 'local',
                      label: 'Project A',
                      path: '/tmp/project-a',
                    },
                  },
                  return: null,
                },
              };
              document.querySelector('aside').append(projectRow);

              const composerShell = document.querySelector('.composer-shell');
              composerShell.__reactFiber$test = {
                memoizedProps: {
                  selectedProject: { projectId: projectID, type: 'local' },
                },
                return: null,
              };

              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              const scopeOptions = [...document.querySelector('[name="scope"]').options]
                .map((option) => option.textContent);
              document.querySelector('[name="name"]').value = 'New chat project prompt';
              document.querySelector('[name="content"]').value = 'Project-only content';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              return {
                headings: [...document.querySelectorAll('.dashboard-prompt-scope > h3')]
                  .map((heading) => heading.textContent),
                scopeOptions,
                scope: stored.prompts[0].scope,
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)

        XCTAssertEqual(values["headings"] as? [String], ["This project · Project A", "Global"])
        XCTAssertEqual(values["scopeOptions"] as? [String], ["All projects", "This project · Project A"])
        XCTAssertEqual(
            values["scope"] as? [String: String],
            ["type": "project", "projectPath": "/tmp/project-a"]
        )
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

    func testPrimaryPromptActionsIgnoreIncompatibleHostButtonTokens() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.documentElement.style.setProperty('--color-background-button-primary', '#000000');
              document.documentElement.style.setProperty('--color-text-button-primary', '#000000');
              document.querySelector('[data-codex-prompt-launcher]').click();
              const newPrompt = document.querySelector('[data-prompt-new]');
              const styles = getComputedStyle(newPrompt);
              return {
                label: newPrompt.textContent.trim(),
                background: styles.backgroundColor,
                foreground: styles.color,
                textFill: styles.webkitTextFillColor,
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)

        XCTAssertEqual(values["label"] as? String, "+ New prompt")
        XCTAssertEqual(values["background"] as? String, "rgb(236, 236, 236)")
        XCTAssertEqual(values["foreground"] as? String, "rgb(33, 33, 33)")
        XCTAssertEqual(values["textFill"] as? String, "rgb(33, 33, 33)")
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

        let injection = try DashboardInjectionResources.load()
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

    func testPromptDialogKeyboardBehaviorAndInMemorySave() async throws {
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
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              return [
                tabWrapped,
                escapeClosedFromOutside,
                !document.querySelector('[data-prompt-form]'),
                document.querySelector('[data-prompt-storage-error]').hidden,
                Boolean(document.querySelector('[data-prompt-use]')),
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

    func testPromptStoreIgnoresObsoleteStorageKeys() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.destroy();
              localStorage.removeItem('codex-dashboard.prompt-library');
              localStorage.setItem('codex-dashboard.saved-prompts', JSON.stringify([{
                id: 'obsolete-prompt', name: 'Obsolete prompt', content: 'Ignore me', section: 'Old',
              }]));
              localStorage.setItem('codex-dashboard.prompt-sections', JSON.stringify(['Old']));
            })()
            """
        )

        let injection = try DashboardInjectionResources.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              return [
                document.querySelectorAll('[data-prompt-use]').length,
                Boolean(document.querySelector('[data-prompt-section="Old"]')),
                localStorage.getItem('codex-dashboard.prompt-library'),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 0)
        XCTAssertEqual(values[1] as? Bool, false)
        XCTAssertNil(values[2] as? String)
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

    func testPromptPresetIsStoredDisplayedAndAppliedBeforeInsertion() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            void (async () => {
              const shell = document.querySelector('.composer-shell');
              const trigger = document.createElement('button');
              trigger.dataset.codexIntelligenceTrigger = 'true';
              trigger.setAttribute('aria-expanded', 'false');
              trigger.textContent = 'Current model';
              shell.append(trigger);
              const applied = [];
              const promptDialogStates = [];
              const triggerDialogStates = [];
              const optionSets = {
                Model: ['5.6 Sol', '5.6 Terra', '5.6 Luna'],
                Effort: ['Low', 'Medium', 'High', 'Extra High'],
                Speed: ['Standard', 'Fast'],
              };
              const removeMenus = () => {
                document.querySelectorAll('[role="menu"]').forEach((menu) => menu.remove());
                trigger.setAttribute('aria-expanded', 'false');
              };
              document.body.addEventListener('click', (event) => {
                if (event.target === document.body) removeMenus();
              });
              trigger.addEventListener('click', () => {
                triggerDialogStates.push(Boolean(document.getElementById(
                  'codex-dashboard-prompt-library-dialog'
                )));
                if (document.getElementById('codex-dashboard-prompt-library-dialog')) return;
                if (trigger.getAttribute('aria-expanded') === 'true') return;
                trigger.setAttribute('aria-expanded', 'true');
                const menu = document.createElement('div');
                menu.setAttribute('role', 'menu');
                const viewToggle = document.createElement('div');
                viewToggle.dataset.modelPickerViewToggle = 'true';
                viewToggle.setAttribute('role', 'menuitem');
                menu.append(viewToggle);
                Object.entries(optionSets).forEach(([kind, labels]) => {
                  const item = document.createElement('div');
                  item.setAttribute('role', 'menuitem');
                  item.setAttribute('aria-label', `${kind} Current`);
                  item.setAttribute('aria-expanded', 'false');
                  item.addEventListener('pointermove', () => {
                    document.querySelectorAll('[data-test-preset-submenu]').forEach((node) => node.remove());
                    item.setAttribute('aria-expanded', 'true');
                    const submenu = document.createElement('div');
                    submenu.setAttribute('role', 'menu');
                    submenu.dataset.testPresetSubmenu = kind;
                    labels.forEach((label) => {
                      const option = document.createElement('div');
                      option.setAttribute('role', 'menuitemradio');
                      option.textContent = label;
                      option.addEventListener('click', () => {
                        applied.push(`${kind}:${label}`);
                        promptDialogStates.push(Boolean(document.getElementById(
                          'codex-dashboard-prompt-library-dialog'
                        )));
                        viewToggle.remove();
                        menu.style.display = 'none';
                        setTimeout(() => { menu.style.display = ''; }, 75);
                      });
                      submenu.append(option);
                    });
                    document.body.append(submenu);
                  });
                  menu.append(item);
                });
                document.body.append(menu);
              });

              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              const presetDefaults = {
                modelValue: document.querySelector('[name="presetModel"]').value,
                effortValue: document.querySelector('[name="presetReasoningEffort"]').value,
                speedValue: document.querySelector('[name="presetSpeed"]').value,
                hasPresetChecked: document.querySelector('[name="hasPreset"]').checked,
                presetFieldsDisabled: document.querySelector('[data-prompt-preset-fields]').disabled,
              };
              document.querySelector('[name="name"]').value = 'Luna fast review';
              document.querySelector('[name="content"]').value = 'Review this change';
              document.querySelector('[name="hasPreset"]').click();
              document.querySelector('[name="presetModel"]').value = 'gpt-5.6-luna';
              document.querySelector('[name="presetReasoningEffort"]').value = 'medium';
              document.querySelector('[name="presetSpeed"]').value = 'fast';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const summary = [...document.querySelectorAll('.dashboard-prompt-preset-summary em')]
                .map((item) => item.textContent);
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              const usePresetCheckbox = document.querySelector('[data-prompt-use-preset]');
              const usesPresetByDefault = usePresetCheckbox.checked;
              usePresetCheckbox.click();
              const storedWithPresetEnabled = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              document.querySelector('[data-prompt-use]').click();
              const deadline = performance.now() + 4000;
              while (document.querySelector('textarea').value !== 'Review this change'
                && performance.now() < deadline) {
                await new Promise((resolve) => setTimeout(resolve, 20));
              }
              window.__promptPresetTestResult = {
                version: stored.version,
                presetDefaults,
                preset: stored.prompts[0].preset,
                usesPresetByDefault,
                usesPresetAfterToggle: storedWithPresetEnabled.prompts[0].usePreset,
                summary,
                applied,
                promptDialogStates,
                triggerDialogStates,
                content: document.querySelector('textarea').value,
                dialogClosed: !document.getElementById('codex-dashboard-prompt-library-dialog'),
              };
            })();
            true
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(window.__promptPresetTestResult)",
            in: webView,
            timeout: .seconds(3)
        )
        let result = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__promptPresetTestResult)"
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))
        let presetDefaults = try XCTUnwrap(values["presetDefaults"] as? [String: Any])

        XCTAssertEqual(values["version"] as? Int, 3)
        XCTAssertEqual(presetDefaults["modelValue"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(presetDefaults["effortValue"] as? String, "medium")
        XCTAssertEqual(presetDefaults["speedValue"] as? String, "standard")
        XCTAssertEqual(presetDefaults["hasPresetChecked"] as? Bool, false)
        XCTAssertEqual(presetDefaults["presetFieldsDisabled"] as? Bool, true)
        XCTAssertEqual(
            values["preset"] as? [String: String],
            ["model": "gpt-5.6-luna", "reasoningEffort": "medium", "speed": "fast"]
        )
        XCTAssertEqual(values["summary"] as? [String], ["5.6 Luna", "Medium", "Fast"])
        XCTAssertEqual(values["usesPresetByDefault"] as? Bool, false)
        XCTAssertEqual(values["usesPresetAfterToggle"] as? Bool, true)
        XCTAssertEqual(
            values["applied"] as? [String],
            ["Model:5.6 Luna", "Effort:Medium", "Speed:Fast"]
        )
        XCTAssertEqual(values["promptDialogStates"] as? [Bool], [false, false, false])
        XCTAssertEqual(values["triggerDialogStates"] as? [Bool], [false])
        XCTAssertEqual(values["content"] as? String, "Review this change")
        XCTAssertEqual(values["dialogClosed"] as? Bool, true)
    }

    func testUnknownSavedModelRemainsVisibleAndRoundTrips() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyPromptLibrary({
                version: 3,
                sections: ['General'],
                prompts: [{
                  id: 'future-model',
                  name: 'Future model prompt',
                  content: 'Keep the model identifier',
                  section: 'General',
                  scope: { type: 'global' },
                  preset: { model: 'gpt-7-preview', reasoningEffort: 'high', speed: 'fast' },
                  usePreset: true,
                }],
              });
              document.querySelector('[data-codex-prompt-launcher]').click();
              const summary = [...document.querySelectorAll('.dashboard-prompt-preset-summary em')]
                .map((item) => item.textContent);
              document.querySelector('[data-prompt-edit]').click();
              const selectedLabel = document.querySelector('[name="presetModel"]')
                .selectedOptions[0].textContent;
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              return [summary, selectedLabel, stored.prompts[0].preset.model];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["Saved model · gpt-7-preview", "High", "Fast"])
        XCTAssertEqual(values[1] as? String, "Saved model · gpt-7-preview")
        XCTAssertEqual(values[2] as? String, "gpt-7-preview")
    }

    func testNewPromptCanBeSavedWithoutModelPreset() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              const fields = document.querySelector('[data-prompt-preset-fields]');
              const defaults = {
                hasPreset: document.querySelector('[name="hasPreset"]').checked,
                fieldsDisabled: fields.disabled,
              };
              document.querySelector('[name="name"]').value = 'Plain prompt';
              document.querySelector('[name="content"]').value = 'Insert without changing my model';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              const row = document.querySelector('[data-prompt-use]');
              return JSON.stringify({
                defaults,
                storedPrompt: stored.prompts[0],
                hasPresetSummary: Boolean(document.querySelector('.dashboard-prompt-preset-summary')),
                usePresetDisabled: row.parentElement.querySelector('[data-prompt-use-preset]').disabled,
              });
            })()
            """
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))
        let defaults = try XCTUnwrap(values["defaults"] as? [String: Any])
        let storedPrompt = try XCTUnwrap(values["storedPrompt"] as? [String: Any])

        XCTAssertEqual(defaults["hasPreset"] as? Bool, false)
        XCTAssertEqual(defaults["fieldsDisabled"] as? Bool, true)
        XCTAssertNil(storedPrompt["preset"])
        XCTAssertNil(storedPrompt["usePreset"])
        XCTAssertEqual(values["hasPresetSummary"] as? Bool, false)
        XCTAssertEqual(values["usePresetDisabled"] as? Bool, true)
    }

    func testFailedPromptPresetRestoresLibraryWithoutInsertingPrompt() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            void (async () => {
              const trigger = document.createElement('button');
              trigger.dataset.codexIntelligenceTrigger = 'true';
              trigger.setAttribute('aria-expanded', 'false');
              trigger.textContent = 'Current model';
              document.querySelector('.composer-shell').append(trigger);

              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Unavailable preset';
              document.querySelector('[name="content"]').value = 'Do not insert this';
              document.querySelector('[name="hasPreset"]').click();
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-use-preset]').click();
              document.querySelector('[data-prompt-use]').click();

              const deadline = performance.now() + 4000;
              while (performance.now() < deadline) {
                const error = document.querySelector('[data-prompt-storage-error]');
                if (error && !error.hidden) break;
                await new Promise((resolve) => setTimeout(resolve, 20));
              }
              const error = document.querySelector('[data-prompt-storage-error]');
              window.__failedPromptPresetResult = {
                dialogOpen: Boolean(document.getElementById(
                  'codex-dashboard-prompt-library-dialog'
                )),
                error: error && !error.hidden ? error.textContent : null,
                content: document.querySelector('textarea').value,
              };
            })();
            true
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(window.__failedPromptPresetResult)",
            in: webView,
            timeout: .seconds(5)
        )
        let result = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__failedPromptPresetResult)"
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))

        XCTAssertEqual(values["dialogOpen"] as? Bool, true)
        XCTAssertEqual(
            values["error"] as? String,
            "Could not apply this prompt’s composer preset. The prompt was not inserted."
        )
        XCTAssertEqual(values["content"] as? String, "")
    }

}
