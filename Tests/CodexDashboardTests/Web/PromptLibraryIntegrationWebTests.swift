import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension PromptLibraryWebTests {
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

}
