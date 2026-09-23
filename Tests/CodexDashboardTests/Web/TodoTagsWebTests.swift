import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoTagsWebTests: SerializedDashboardWebTestCase {
    func testTagsButtonClearsTitlebarAtReducedHostZoom() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const page = document.getElementById('codex-dashboard-todo-page');
          page.parentElement.style.zoom = '0.5';
          window.__codexDashboard.openTodos();
          const button = page.querySelector('[data-todo-manage-tags]');
          return [button.getBoundingClientRect().top >= 50,
            page.style.getPropertyValue('--todo-top-inset')];
        })()
        """) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? String, "112px")
    }

    func testTodoTagsCanBeCreatedPersistedAndRemoved() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const tagPicker = form.querySelector('[data-todo-new-tag]');
              const unavailableBeforeCreation = tagPicker.options.length === 1;
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const tagDialog = document.querySelector('[data-todo-tag-dialog]');
              tagDialog.querySelector('[data-todo-tag-dialog-close]').click();
              await window.__waitForTodoSaves?.();
              const closesFromControl = !tagDialog.open;
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              tagDialog.querySelector('[data-todo-tag-name]').value = 'Work';
              tagDialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              tagPicker.value = 'Work';
              tagPicker.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-title]').value = 'Send update';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const renderedTag = document.querySelector('[data-todo-id] .todo-tag').textContent.trim();
              document.querySelector('[data-todo-tag-remove]').click();
              await window.__waitForTodoSaves?.();
              return [unavailableBeforeCreation, closesFromControl, JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')), stored.tags, renderedTag, JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].tags];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? [String], ["Work"])
        XCTAssertEqual(values[3] as? [String], ["Work"])
        XCTAssertEqual(values[4] as? String, "Work×")
        XCTAssertEqual(values[5] as? [String], [])
    }

    func testTagCanBeAddedToAnExistingTodo() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Follow up';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Important';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              const picker = document.querySelector('[data-todo-id] [data-todo-tag]');
              picker.value = 'Important';
              picker.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              return [stored.tags, document.querySelector('[data-todo-id] .todo-tag').textContent.trim()];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["Important"])
        XCTAssertEqual(values[1] as? String, "Important×")
    }

    func testTodoTagsHaveNoCharacterLimit() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const tag = 'A'.repeat(80);
              window.__codexDashboard.openTodos();
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const input = document.querySelector('[data-todo-tag-name]');
              input.value = tag;
              input.form.requestSubmit();
              await window.__waitForTodoSaves?.();
              return [input.maxLength, JSON.parse(localStorage.getItem('codex-dashboard.todo-tags'))[0]];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, -1)
        XCTAssertEqual(values[1] as? String, String(repeating: "A", count: 80))
    }

    func testManagedTagDeletionUnassignsItFromTodosAndPersists() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Work';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-tag]').value = 'Work';
              form.querySelector('[data-todo-new-tag]').dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-title]').value = 'Send update';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const deleteButton = dialog.querySelector('[data-todo-managed-tag-remove="Work"]');
              const accessible = deleteButton.getAttribute('aria-label');
              deleteButton.click();
              await window.__waitForTodoSaves?.();
              return [
                accessible,
                JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')),
                JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].tags,
                document.querySelector('[data-todo-managed-tag-remove]') === null,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Delete tag Work from all to-dos")
        XCTAssertEqual(values[1] as? [String], [])
        XCTAssertEqual(values[2] as? [String], [])
        XCTAssertEqual(values[3] as? Bool, true)
    }

    func testManagedTagCanBeRenamedAcrossTodos() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Work';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-tag]').value = 'Work';
              form.querySelector('[data-todo-new-tag]').dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-title]').value = 'Send update';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const renameButton = dialog.querySelector('[data-todo-managed-tag-edit="Work"]');
              const accessible = renameButton.getAttribute('aria-label');
              renameButton.click();
              await window.__waitForTodoSaves?.();
              const name = dialog.querySelector('[data-todo-tag-name]');
              const savesRename = dialog.querySelector('[data-todo-tag-form] button').textContent === 'Save tag';
              name.value = 'Client';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              return [
                accessible,
                savesRename,
                JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')),
                JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].tags,
                document.querySelector('[data-todo-id] .todo-tag').textContent.trim(),
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Rename tag Work")
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? [String], ["Client"])
        XCTAssertEqual(values[3] as? [String], ["Client"])
        XCTAssertEqual(values[4] as? String, "Client×")
    }

    func testTagDialogIsCenteredAndItsCloseControlDismissesIt() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              const rect = dialog.getBoundingClientRect();
              const centered = Math.abs(rect.left + rect.width / 2 - window.innerWidth / 2) < 1
                && Math.abs(rect.top + rect.height / 2 - window.innerHeight / 2) < 1;
              dialog.querySelector('[data-todo-tag-dialog-close]').click();
              await window.__waitForTodoSaves?.();
              return [dialog.parentElement.id, centered, !dialog.open];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "codex-dashboard-todo-dialogs")
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
    }

    func testTagDialogShowsManagedRowsAndCanCancelRename() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              document.querySelector('[data-todo-manage-tags]').click();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              const empty = dialog.querySelector('.todo-tag-empty')?.textContent.includes('No tags yet');
              dialog.querySelector('[data-todo-tag-name]').value = 'A long tag name that should stay readable';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              const row = dialog.querySelector('.todo-managed-tag');
              const details = [row.querySelector('.todo-managed-tag-name').textContent.trim(),
                row.querySelector('.todo-managed-tag-usage').textContent.trim(),
                dialog.querySelector('[data-todo-tag-count]').textContent.trim()];
              row.querySelector('[data-todo-managed-tag-edit]').click();
              const renaming = dialog.querySelector('[data-todo-tag-cancel]').hidden === false;
              dialog.querySelector('[data-todo-tag-cancel]').click();
              return [empty, ...details, renaming,
                dialog.querySelector('[data-todo-tag-name]').value,
                dialog.querySelector('[data-todo-tag-form] button[type="submit"]').textContent];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "A long tag name that should stay readable")
        XCTAssertEqual(values[2] as? String, "0 to-dos")
        XCTAssertEqual(values[3] as? String, "1 of 8")
        XCTAssertEqual(values[4] as? Bool, true)
        XCTAssertEqual(values[5] as? String, "")
        XCTAssertEqual(values[6] as? String, "Create tag")
    }

    func testTodosCanBeFilteredByProjectAndTag() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-a"
                  data-app-action-sidebar-project-label="Project A"></div>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-b"
                  data-app-action-sidebar-project-label="Project B"></div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const add = async (title, projectID = '', tag = '') => {
                form.querySelector('[data-todo-new-project]').value = projectID;
                form.querySelector('[data-todo-new-project]').dispatchEvent(new Event('change', { bubbles: true }));
                await window.__waitForTodoSaves?.();
                if (tag) {
                  form.querySelector('[data-todo-new-tag]').value = tag;
                  form.querySelector('[data-todo-new-tag]').dispatchEvent(new Event('change', { bubbles: true }));
                  await window.__waitForTodoSaves?.();
                }
                form.querySelector('[data-todo-new-title]').value = title;
                form.requestSubmit();
                await window.__waitForTodoSaves?.();
              };
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Work';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              await add('Project A work', 'project-a', 'Work');
              await add('Project B task', 'project-b');
              await add('Unassigned work', '', 'Work');
              const titles = () => [...document.querySelectorAll('[data-todo-title]')].map((input) => input.value);
              const project = document.querySelector('[data-todo-project-filter]');
              const tag = document.querySelector('[data-todo-tag-filter]');
              const projectOptions = [...project.options].map((option) => [option.value, option.textContent]);
              const tagOptions = [...tag.options].map((option) => option.textContent);
              project.value = 'project-a';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const projectOnly = titles();
              tag.value = 'Work';
              tag.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const combined = titles();
              project.value = '';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const tagOnly = titles();
              project.value = '__none__';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const unassignedOnly = titles();
              return [projectOptions, tagOptions, projectOnly, combined, tagOnly, unassignedOnly];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [[String]], [
            ["", "All projects"], ["__none__", "No project (1)"],
            ["project-a", "Project A (1)"], ["project-b", "Project B (1)"],
        ])
        XCTAssertEqual(values[1] as? [String], ["All tags", "Work (2)"])
        XCTAssertEqual(values[2] as? [String], ["Project A work"])
        XCTAssertEqual(values[3] as? [String], ["Project A work"])
        XCTAssertEqual(values[4] as? [String], ["Unassigned work", "Project A work"])
        XCTAssertEqual(values[5] as? [String], ["Unassigned work"])
    }

    func testTagPickerOptionsRemainReadableInTheNativeMenu() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"><style>:root { --app-color-background-surface: #fff; --app-color-text-foreground: #1f1f1f; }</style></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const option = document.querySelector('[data-todo-new-tag] option');
              const style = getComputedStyle(option);
              return [style.backgroundColor, style.color];
            })()
            """
        ) as? [String]

        XCTAssertEqual(result, ["rgb(255, 255, 255)", "rgb(31, 31, 31)"])
    }
}
