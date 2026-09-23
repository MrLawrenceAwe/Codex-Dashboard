import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoImagesWebTests: SerializedDashboardWebTestCase {
    func testNewTaskTransfersTheTodoImageToTheComposer() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dashboard"
                  data-app-action-sidebar-project-label="Codex Dashboard"></div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const project = form.querySelector('[data-todo-new-project]');
              project.value = 'dashboard';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const title = form.querySelector('[data-todo-new-title]');
              title.value = 'Review the image';
              const image = new File([new Uint8Array([137, 80, 78, 71])], 'handoff.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [image], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-image-status]').textContent.includes('ready')",
            in: webView
        )
        _ = try await webView.evaluateAsyncJavaScript(
            "document.querySelector('[data-todo-form]').requestSubmit()"
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-thread]') !== null",
            in: webView
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.fetch = () => Promise.reject(new TypeError('Codex renderer rejects data URLs'));
              document.getElementById('new-chat').addEventListener('click', () => {
                const composer = document.createElement('textarea');
                composer.placeholder = 'Do anything';
                composer.addEventListener('paste', (event) => {
                  const file = event.clipboardData?.files?.[0];
                  window.__todoHandoffImage = file ? [file.name, file.type, file.size] : null;
                  event.preventDefault();
                });
                document.body.append(composer);
              });
              document.querySelector('[data-todo-new-thread]').click();
              await window.__waitForTodoSaves?.();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Array.isArray(window.__todoHandoffImage)",
            in: webView
        )
        let result = try await webView.evaluateAsyncJavaScript(
            "[document.querySelector('textarea[placeholder=\"Do anything\"]').value, ...window.__todoHandoffImage]"
        ) as? [AnyHashable]
        XCTAssertEqual(result, ["Review the image", "handoff.png", "image/png", 4])
    }

    func testTodoImageCanBePastedDuringAdditionReplacedAndPreservedWhenCompleted() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const title = form.querySelector('[data-todo-new-title]');
              title.value = 'Review design';
              const file = new File(
                [new Uint8Array([137, 80, 78, 71])],
                'mockup.png',
                { type: 'image/png' }
              );
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [file], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(document.querySelector('[data-todo-new-image-preview]:not([hidden]) img')?.src.startsWith('data:image/png;base64,'))",
            in: webView
        )
        let draftPreview = try await webView.evaluateAsyncJavaScript(
            "[document.querySelector('[data-todo-new-image-preview] img').alt, document.querySelector('[data-todo-new-image-status]').textContent]"
        ) as? [String]
        XCTAssertEqual(draftPreview, ["mockup.png", "Image ready to attach when you add this to-do."])
        let draftDialog = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              document.querySelector('[data-todo-new-image-open]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-image-dialog]');
              const result = [dialog.open, dialog.querySelector('img').alt];
              dialog.close();
              return result;
            })()
            """
        ) as? [AnyHashable]
        XCTAssertEqual(draftDialog, [true, "mockup.png"])
        _ = try await webView.evaluateAsyncJavaScript("document.querySelector('[data-todo-form]').requestSubmit()")
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-image-preview]') !== null",
            in: webView
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-image-preview]').hidden",
            in: webView
        )

        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const title = document.querySelector('[data-todo-title]');
              const replacement = new File(
                [new Uint8Array([137, 80, 78, 71])],
                'updated-mockup.png',
                { type: 'image/png' }
              );
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [replacement], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].image.name === 'updated-mockup.png'",
            in: webView
        )

        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const preview = document.querySelector('[data-todo-image-preview]');
              preview.click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-image-dialog]');
              const checkbox = document.querySelector('[data-todo-completed]');
              checkbox.checked = true;
              checkbox.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              document.querySelector('[data-todo-filter="completed"]').click();
              await window.__waitForTodoSaves?.();
              const values = [
                stored.image.name,
                stored.image.type,
                !Object.hasOwn(stored.image, 'dataURL') || stored.image.dataURL === '',
                dialog.open,
                dialog.querySelector('img').alt,
                document.querySelector('[data-todo-image-preview]') !== null,
                document.querySelector('[data-todo-image-actions]') === null,
                document.querySelectorAll('input[type="file"]').length === 0,
              ];
              dialog.close();
              return values;
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "updated-mockup.png")
        XCTAssertEqual(values[1] as? String, "image/png")
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "updated-mockup.png")
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertEqual(values[6] as? Bool, true)
        XCTAssertEqual(values[7] as? Bool, true)
    }

    func testTodoImagePasteShowsAnErrorForOversizedImages() async throws {
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
              form.querySelector('[data-todo-new-title]').value = 'Review notes';
              const image = new File([new Uint8Array(2 * 1024 * 1024 + 1)], 'large.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [image], items: [] } });
              form.querySelector('[data-todo-new-title]').dispatchEvent(paste);
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              return [
                document.querySelector('[data-todo-image-error]').textContent,
                document.querySelectorAll('[data-todo-id]').length === 0,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Images must be 2 MB or smaller.")
        XCTAssertEqual(values[1] as? Bool, true)
    }

    func testTodoImageDoesNotStoreItsDataURLInLocalStorage() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const title = document.querySelector('[data-todo-new-title]');
              title.value = 'Keep screenshot';
              const image = new File([new Uint8Array(24 * 1024)], 'screenshot.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [image], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-image-status]').textContent.includes('ready')",
            in: webView
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const realStorage = window.localStorage;
              window.__todoTestStorage = realStorage;
              Object.defineProperty(window, 'localStorage', {
                configurable: true,
                value: {
                  getItem: realStorage.getItem.bind(realStorage),
                  setItem(key, value) {
                    if (value.length > 1024) throw new Error('Storage full');
                    return realStorage.setItem(key, value);
                  },
                },
              });
              document.querySelector('[data-todo-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelectorAll('[data-todo-id]').length === 1",
            in: webView
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.localStorage.getItem('codex-dashboard.todos') !== null",
            in: webView
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              Object.defineProperty(window, 'localStorage', {
                configurable: true,
                value: window.__todoTestStorage,
              });
              delete window.__todoTestStorage;
              const stored = JSON.parse(window.localStorage.getItem('codex-dashboard.todos')).items[0];
              return [document.querySelectorAll('[data-todo-id]').length, stored.image.dataURL,
                document.querySelector('[data-todo-storage-error]').hidden];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 1)
        XCTAssertEqual(values[1] as? String, "")
        XCTAssertEqual(values[2] as? Bool, true)
    }

    func testPastedTodoImageCanBeRemovedFromTheAddBar() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const title = document.querySelector('[data-todo-new-title]');
              const file = new File([new Uint8Array([137, 80, 78, 71])], 'draft.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [], items: [
                { kind: 'file', type: 'image/png', getAsFile: () => file },
              ] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "!document.querySelector('[data-todo-new-image-preview]').hidden",
            in: webView
        )

        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              document.querySelector('[data-todo-new-image-remove]').click();
              await window.__waitForTodoSaves?.();
              return [
                document.querySelector('[data-todo-new-image-preview]').hidden,
                document.querySelector('[data-todo-new-image-preview] img').getAttribute('src'),
                document.querySelector('[data-todo-new-image-status]').hidden,
                document.activeElement === document.querySelector('[data-todo-new-title]'),
              ];
            })()
            """
        ) as? [AnyHashable]
        XCTAssertEqual(result, [true, "", true, true])
    }
}
