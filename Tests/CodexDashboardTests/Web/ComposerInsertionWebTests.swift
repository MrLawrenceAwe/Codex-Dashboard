import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class ComposerInsertionWebTests: SerializedDashboardWebTestCase {
    func testMultilineTodoTransfersOnceIntoParagraphComposer() async throws {
        let webView = try await transferWebView()
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          const fixture = window.__transferFixture;
          fixture.props.conversationId = null;
          fixture.props.selectedProject = { type: 'local', projectId: 'project' };
          fixture.item.body = 'First line\\nSecond line\\n\\nLast paragraph';
          const editor = document.createElement('div');
          editor.contentEditable = 'true';
          editor.setAttribute('role', 'textbox');
          editor.classList.add('ProseMirror');
          fixture.composer.replaceWith(editor);
          class Slice { constructor(content) { this.content = content; } }
          const transaction = {
            replaceSelection(slice) { this.slice = slice; return this; },
            scrollIntoView() { return this; },
          };
          let insertions = 0;
          fixture.props.composerController = { view: {
            dom: editor,
            focus: () => editor.focus(),
            state: {
              schema: {
                text: text => ({ text }),
                nodes: {
                  paragraph: { create: (_, child) => ({ text: child?.text || '' }) },
                  doc: { create: (_, paragraphs) => ({ content: paragraphs }) },
                },
              },
              doc: { slice: () => new Slice([]) },
              tr: transaction,
            },
            dispatch: ({ slice }) => {
              insertions += 1;
              for (const paragraph of slice.content) {
                const node = document.createElement('p');
                node.textContent = paragraph.text;
                if (!paragraph.text) node.append(document.createElement('br'));
                editor.append(node);
              }
            },
          } };
          await fixture.actions.openTodoInNewThread(fixture.item);
          return [insertions, [...editor.querySelectorAll('p')].map(node => node.textContent).join('\\n'),
            !!document.querySelector('[data-todo-preset-warning]')];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [1, "Todo title\n\nFirst line\nSecond line\n\nLast paragraph", false])
    }

    func testPromptPlaceholdersPreserveLiteralSelectionAndClipboardText() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          const composer = document.querySelector('textarea');
          const selection = "echo $$ $& $'selected' $`";
          const clipboard = "echo $$ $& $'copied' $`";
          Object.defineProperty(navigator, 'clipboard', { value: { readText: async () => clipboard } });
          composer.value = selection;
          composer.focus();
          composer.setSelectionRange(0, selection.length);
          document.querySelector('[data-codex-prompt-library-button]').click();
          document.querySelector('[data-prompt-new]').click();
          document.querySelector('[name="name"]').value = 'Literal text';
          document.querySelector('[name="content"]').value = 'Selection: {{selection}} Clipboard: {{clipboard}} End';
          document.querySelector('[data-prompt-form] button[type="submit"]').click();
          document.querySelector('[data-prompt-use]').click();
          await new Promise(resolve => setTimeout(resolve, 100));
          return [composer.value, `Selection: ${selection} Clipboard: ${clipboard} End`];
        })()
        """) as? [String]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0], values[1])
    }

    func testTodoPasteWaitsForDestinationEditorDespiteSelectedSidebarRow() async throws {
        let webView = try await transferWebView()
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          const { actions, picker, composer, props } = window.__transferFixture;
          document.querySelector('[data-app-action-sidebar-thread-id]').addEventListener('click', event => {
            event.currentTarget.setAttribute('aria-current', 'page');
            setTimeout(() => {
              window.__oldDraft = composer.value;
              props.conversationId = 'destination';
              composer.value = 'Destination draft';
              composer.setSelectionRange(composer.value.length, composer.value.length);
            }, 1200);
          });
          actions.chooseTodoThread(window.__transferFixture.item, document.getElementById('todo-row'));
          picker.value = 'destination';
          picker.onchange();
          for (let attempt = 0; attempt < 200 && !composer.value.includes('Todo details'); attempt += 1) {
            await new Promise(resolve => setTimeout(resolve, 25));
          }
          return [window.__oldDraft, composer.value];
        })()
        """) as? [String]
        XCTAssertEqual(result, ["Previous draft", "Destination draft\n\nTodo title\n\nTodo details"])
    }

    func testTodoPasteStopsWhenNavigationChangesWhilePresetIsPending() async throws {
        let webView = try await transferWebView()
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          const fixture = window.__transferFixture;
          fixture.item.preset = { model: 'model' };
          document.querySelector('[data-app-action-sidebar-thread-id]').addEventListener('click', event => {
            event.currentTarget.setAttribute('aria-current', 'page');
            fixture.props.conversationId = 'destination';
          });
          window.__todoComposerActionsForTests.picker.applyPreset = async () => {
            fixture.props.conversationId = 'another-task';
            fixture.composer.value = 'Unrelated draft';
            await new Promise(resolve => setTimeout(resolve, 50));
            window.__presetCompleted = true;
            return true;
          };
          fixture.actions.chooseTodoThread(fixture.item, document.getElementById('todo-row'));
          fixture.picker.value = 'destination';
          fixture.picker.onchange();
          for (let attempt = 0; attempt < 40 && !window.__presetCompleted; attempt += 1) {
            await new Promise(resolve => setTimeout(resolve, 100));
          }
          await new Promise(resolve => setTimeout(resolve, 200));
          return [fixture.composer.value, window.__presetCompleted === true];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Unrelated draft", true])
    }

    func testPresetStopsBeforeSelectingControlsForAnotherTask() async throws {
        let webView = try await transferWebView()
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          const fixture = window.__transferFixture;
          fixture.props.conversationId = 'destination';
          const trigger = document.createElement('button');
          trigger.dataset.codexIntelligenceTrigger = 'true';
          trigger.setAttribute('aria-expanded', 'false');
          trigger.addEventListener('click', () => {
            trigger.setAttribute('aria-expanded', 'true');
            setTimeout(() => {
              fixture.props.conversationId = 'another-task';
              const menu = document.createElement('div');
              menu.dataset.modelPickerView = 'simple';
              const toggle = document.createElement('button');
              toggle.setAttribute('role', 'menuitemcheckbox');
              toggle.setAttribute('aria-label', 'Enable fast mode');
              toggle.setAttribute('aria-checked', 'false');
              toggle.addEventListener('click', () => { window.__speedChanged = true; });
              menu.append(toggle);
              document.body.append(menu);
            }, 50);
          });
          document.getElementById('composer-shell').append(trigger);
          const applied = await window.__todoComposerActionsForTests.picker.applyPreset(
            { speed: 'fast' }, { isCurrent: () => fixture.props.conversationId === 'destination' },
          );
          return [applied, window.__speedChanged === true, fixture.props.conversationId];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, false, "another-task"])
    }

    private func transferWebView() async throws -> WKWebView {
        let webView = DashboardWebTestHarness.makeWebView()
        webView.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <aside role="navigation"><button class="sidebar-item">New chat</button>
            <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project"
              data-app-action-sidebar-project-label="Project"></div>
            <button data-app-action-sidebar-thread-id="local:destination">Destination</button>
          </aside>
          <main><div id="composer-shell"><textarea placeholder="Do anything">Previous draft</textarea></div></main>
          <div id="todo-row"><button data-todo-paste-in-thread></button><select data-todo-paste-thread hidden></select></div>
        </body></html>
        """, baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"))
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let injection = try InjectionBundle.load().mountExpression.replacingOccurrences(
            of: "function createTodoComposerActions({",
            with: "window.__todoComposerActionsForTests = { create: createTodoComposerActions, picker: composerModelPicker };\nfunction createTodoComposerActions({"
        )
        _ = try await webView.evaluateJavaScript(injection)
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const props = { conversationId: 'previous' };
          document.getElementById('composer-shell').__reactFiber$test = { memoizedProps: props };
          const item = { id: 'todo', title: 'Todo title', body: 'Todo details', project: { id: 'project' } };
          const actions = window.__todoComposerActionsForTests.create({
            isDestroyed: () => false, pageState: { open() {}, close() {} },
            threadReferencesForProject: () => [{ id: 'destination', title: 'Destination' }],
            getItems: () => [item],
          });
          window.__transferFixture = { props, item, actions, composer: document.querySelector('textarea'),
            picker: document.querySelector('[data-todo-paste-thread]') };
        })()
        """)
        return webView
    }
}
