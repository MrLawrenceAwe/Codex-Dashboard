import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoPersistenceWebTests: SerializedDashboardWebTestCase {
    private func webView() async throws -> WKWebView {
        try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
    }

    func testLegacyTodoDocumentsMigrateWithoutLosingProjectsTagsOrImages() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const results = [];
          for (const version of [1, 2, 3, 4, 5]) {
            localStorage.clear();
            const project = { id: 'project-a', name: 'Project A' };
            const image = { dataURL: 'data:image/png;base64,aA==', type: 'image/png', size: 1, name: 'test.png' };
            const item = { id: 'todo-a', title: 'Saved task', image, createdAt: 1, updatedAt: 2 };
            Object.assign(item, version < 4 ? { badges: ['Work'], projectBadge: project }
              : version === 4 ? { tags: ['Work'], projectTag: project }
              : { tags: ['Work'], project });
            localStorage.setItem('codex-dashboard.todos', JSON.stringify({ version, items: [item] }));
            localStorage.setItem('codex-dashboard.todo-badges', JSON.stringify(['Personal']));
            const loaded = store.load();
            const tags = store.loadTags(loaded);
            const migrated = JSON.parse(localStorage.getItem('codex-dashboard.todos'));
            results.push(migrated.version === 6 && loaded[0].project.id === 'project-a'
              && loaded[0].tags[0] === 'Work' && loaded[0].image.dataURL === image.dataURL
              && loaded[0].createdAt === 1 && loaded[0].updatedAt === 2
              && tags.includes('Personal') && tags.includes('Work')
              && localStorage.getItem('codex-dashboard.todo-badges') === null
              && !Object.hasOwn(migrated.items[0], 'projectTag')
              && !Object.hasOwn(migrated.items[0], 'projectBadge')
              && !Object.hasOwn(migrated.items[0], 'badges'));
          }
          return results;
        })()
        """) as? [Bool]
        XCTAssertEqual(result, [true, true, true, true, true])
    }

    func testFailedMigrationWriteStillLoadsDataAndPreservesOriginalDocument() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const storage = window.localStorage;
          const original = JSON.stringify({ version: 4, items: [{ id: 'a', title: 'Keep me',
            tags: ['Work'], projectTag: { id: 'p', name: 'Project' } }] });
          storage.setItem('codex-dashboard.todos', original);
          Object.defineProperty(window, 'localStorage', { configurable: true, value: {
            getItem: storage.getItem.bind(storage), setItem() { throw new Error('Full'); },
          }});
          const items = window.__todoStoreForTests.load();
          Object.defineProperty(window, 'localStorage', { configurable: true, value: storage });
          return [items[0].project.id, items[0].tags[0], storage.getItem('codex-dashboard.todos') === original];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["p", "Work", true])
    }

    func testUnsupportedAndUnreadableTodoDocumentsAreNeverOverwritten() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const storage = window.localStorage;
          const results = [];
          for (const original of [
            JSON.stringify({ version: 7, items: [{ id: 'future', title: 'Keep me' }] }),
            '{invalid json',
          ]) {
            storage.setItem('codex-dashboard.todos', original);
            const loaded = store.load();
            const reason = store.writeProtectionReason();
            const saved = await store.save([store.create('Replacement')], []);
            results.push(loaded.length === 0 && Boolean(reason) && !saved
              && storage.getItem('codex-dashboard.todos') === original);
          }
          return results;
        })()
        """) as? [Bool]
        XCTAssertEqual(result, [true, true])
    }

    func testNewerTodoDocumentShowsReadOnlyMessage() async throws {
        let view = try await webView()
        let injection = try InjectionBundle.load()
        let result = try await view.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.destroy();
          localStorage.setItem('codex-dashboard.todos', JSON.stringify({
            version: 7, items: [{ id: 'future', title: 'Keep me' }],
          }));
          return true;
        })()
        """) as? Bool
        XCTAssertEqual(result, true)
        _ = try await view.evaluateJavaScript(DashboardWebTestHarness.trackedTodoInjection(injection))
        let state = try await view.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.openTodos();
          const notice = document.querySelector('[data-todo-storage-error]');
          return [!notice.hidden, notice.textContent.includes('newer dashboard version'),
            document.querySelector('[data-todo-new-title]').disabled,
            document.querySelector('[data-todo-form] button[type="submit"]').disabled];
        })()
        """) as? [Bool]
        XCTAssertEqual(state, [true, true, true, true])
    }

    func testQueuedImageAndTextSavesKeepOrderAndRecoverAfterFailure() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const storage = window.localStorage;
          const writes = [];
          Object.defineProperty(window, 'localStorage', { configurable: true, value: {
            getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
            setItem(key, value) {
              if (key === 'codex-dashboard.todos') {
                const title = JSON.parse(value).items[0].title;
                writes.push(title);
                if (title === 'Failed edit') throw new Error('Full');
              }
              storage.setItem(key, value);
            },
          }});
          const image = { dataURL: 'data:image/png;base64,aA==', type: 'image/png', size: 1, name: 'test.png' };
          const item = store.create('Image draft', '', image, ['Work']);
          const first = store.save([item], ['Work']);
          const failed = store.save([{ ...item, title: 'Failed edit' }], ['Temporary']);
          const last = store.save([{ ...item, title: 'Latest edit' }], ['Work']);
          const results = await Promise.all([first, failed, last]);
          const saved = store.load();
          const hydrated = await store.hydrate(saved);
          Object.defineProperty(window, 'localStorage', { configurable: true, value: storage });
          return [first instanceof Promise && failed instanceof Promise && last instanceof Promise,
            results, writes, saved[0].title, hydrated[0].image.dataURL, store.loadTags(saved)];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? [Bool], [true, false, true])
        XCTAssertEqual(values[2] as? [String], ["Image draft", "Failed edit", "Latest edit"])
        XCTAssertEqual(values[3] as? String, "Latest edit")
        XCTAssertEqual(values[4] as? String, "data:image/png;base64,aA==")
        XCTAssertEqual(values[5] as? [String], ["Work"])
    }

    func testFailedImageReplacementPreservesDurableImage() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const oldImage = { dataURL: 'data:image/png;base64,aA==', type: 'image/png', size: 1, name: 'old.png' };
          const newImage = { dataURL: 'data:image/png;base64,Yg==', type: 'image/png', size: 1, name: 'new.png' };
          const item = store.create('Saved image', '', oldImage);
          await store.save([item], []);
          const replacement = store.normalizeItem({ ...item, image: newImage });
          const storage = window.localStorage;
          Object.defineProperty(window, 'localStorage', { configurable: true, value: {
            getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
            setItem(key, value) {
              if (key === 'codex-dashboard.todos') throw new Error('Full');
              storage.setItem(key, value);
            },
          }});
          const saved = await store.save([replacement], []);
          Object.defineProperty(window, 'localStorage', { configurable: true, value: storage });
          const [restored] = await store.hydrate(store.load());
          return [saved, restored.image.dataURL, restored.image.name,
            replacement.image.storageKey !== item.image.storageKey];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, "data:image/png;base64,aA==", "old.png", true])
    }

    func testFailedImageRemovalPreservesDurableImage() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const image = { dataURL: 'data:image/png;base64,aA==', type: 'image/png', size: 1, name: 'test.png' };
          const item = store.create('Saved image', '', image);
          await store.save([item], []);
          const storage = window.localStorage;
          Object.defineProperty(window, 'localStorage', { configurable: true, value: {
            getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
            setItem(key, value) {
              if (key === 'codex-dashboard.todos') throw new Error('Full');
              storage.setItem(key, value);
            },
          }});
          const saved = await store.save([{ ...item, image: null }], []);
          Object.defineProperty(window, 'localStorage', { configurable: true, value: storage });
          const [restored] = await store.hydrate(store.load());
          return [saved, restored.image.dataURL];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, "data:image/png;base64,aA=="])
    }

    func testDestroyDisconnectsProjectObserverAndIgnoresPendingSaveUI() async throws {
        let view = try await webView()
        _ = try await view.evaluateJavaScript("""
        window.__codexDashboard.destroy();
        window.__projectObservers = [];
        const OriginalObserver = window.MutationObserver;
        window.MutationObserver = class extends OriginalObserver {
          observe(target, options) {
            if (options.attributeFilter?.includes('data-app-action-sidebar-project-id')) {
              this.isProjectObserverActive = true;
              window.__projectObservers.push(this);
            }
            super.observe(target, options);
          }
          disconnect() { this.isProjectObserverActive = false; super.disconnect(); }
        };
        true;
        """)
        let injection = try InjectionBundle.load()
        _ = try await view.evaluateJavaScript(DashboardWebTestHarness.trackedTodoInjection(injection))
        _ = try await view.evaluateJavaScript("""
        window.__codexDashboard.openTodos();
        window.__todoStoreForTests.save = () => new Promise(resolve => { window.__finishOldSave = resolve; });
        window.__oldTitle = document.querySelector('[data-todo-new-title]');
        window.__oldTitle.value = 'Old pending draft';
        document.querySelector('[data-todo-form]').requestSubmit();
        window.__codexDashboard.destroy();
        true;
        """)
        let disconnected = try await view.evaluateJavaScript(
            "window.__projectObservers.length > 0 && window.__projectObservers.every(observer => !observer.isProjectObserverActive)"
        ) as? Bool
        XCTAssertEqual(disconnected, true)
        _ = try await view.evaluateJavaScript(DashboardWebTestHarness.trackedTodoInjection(injection))
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const title = document.querySelector('[data-todo-new-title]');
          title.value = 'Replacement draft';
          window.__finishOldSave(true);
          await Promise.resolve();
          await Promise.resolve();
          return [window.__oldTitle.value, title.value, document.querySelectorAll('[data-todo-id]').length];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Old pending draft", "Replacement draft", 0])
    }

    func testTagDialogWorksAfterPageRepairAndDashboardReinjection() async throws {
        let view = try await webView()
        let injection = try InjectionBundle.load()
        let repaired = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          document.getElementById('codex-dashboard-todo-page').remove();
          window.__codexDashboard.ensureMounted();
          document.querySelector('[data-todo-manage-tags]').click();
          document.querySelector('[data-todo-tag-name]').value = 'After repair';
          document.querySelector('[data-todo-tag-form]').requestSubmit();
          await window.__waitForTodoSaves();
          return [
            document.querySelectorAll('#codex-dashboard-todo-dialogs').length,
            JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')),
          ];
        })()
        """) as? [Any]
        XCTAssertEqual(repaired?[0] as? Int, 1)
        XCTAssertEqual(repaired?[1] as? [String], ["After repair"])

        let removed = try await view.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.destroy();
          return document.querySelectorAll('#codex-dashboard-todo-dialogs').length;
        })()
        """) as? Int
        XCTAssertEqual(removed, 0)

        _ = try await view.evaluateJavaScript(DashboardWebTestHarness.trackedTodoInjection(injection))
        let reinjected = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          document.querySelector('[data-todo-manage-tags]').click();
          document.querySelector('[data-todo-tag-name]').value = 'After reinjection';
          document.querySelector('[data-todo-tag-form]').requestSubmit();
          await window.__waitForTodoSaves();
          return [
            document.querySelectorAll('#codex-dashboard-todo-dialogs').length,
            JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')),
          ];
        })()
        """) as? [Any]
        XCTAssertEqual(reinjected?[0] as? Int, 1)
        XCTAssertEqual(reinjected?[1] as? [String], ["After repair", "After reinjection"])
    }

    func testTagsButtonRepairsRemovedDialogHostWithoutLosingDraft() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const title = document.querySelector('[data-todo-new-title]');
          title.value = 'Unsubmitted draft';
          document.getElementById('codex-dashboard-todo-dialogs').remove();
          document.querySelector('[data-todo-manage-tags]').click();
          const dialog = document.querySelector('[data-todo-tag-dialog]');
          const opened = dialog?.open === true;
          dialog.querySelector('[data-todo-tag-name]').value = 'Restored tag';
          dialog.querySelector('[data-todo-tag-form]').requestSubmit();
          await window.__waitForTodoSaves();
          return [opened, title.value,
            document.querySelectorAll('#codex-dashboard-todo-dialogs').length,
            JSON.parse(localStorage.getItem('codex-dashboard.todo-tags'))];
        })()
        """) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? String, "Unsubmitted draft")
        XCTAssertEqual(result?[2] as? Int, 1)
        XCTAssertEqual(result?[3] as? [String], ["Restored tag"])
    }

    func testFailedTagRenameAndDeletionRestoreAssignmentsAndCatalog() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          document.querySelector('[data-todo-manage-tags]').click();
          const name = document.querySelector('[data-todo-tag-name]');
          const tagForm = document.querySelector('[data-todo-tag-form]');
          name.value = 'Work';
          tagForm.requestSubmit();
          await window.__waitForTodoSaves();
          const tag = document.querySelector('[data-todo-new-tag]');
          tag.value = 'Work';
          tag.dispatchEvent(new Event('change', { bubbles: true }));
          document.querySelector('[data-todo-new-title]').value = 'Saved item';
          document.querySelector('[data-todo-form]').requestSubmit();
          await window.__waitForTodoSaves();
          const storage = window.localStorage;
          Object.defineProperty(window, 'localStorage', { configurable: true, value: {
            getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
            setItem(key, value) {
              if (key === 'codex-dashboard.todos') throw new Error('Full');
              storage.setItem(key, value);
            },
          }});
          document.querySelector('[data-todo-managed-tag-edit]').click();
          name.value = 'Home';
          tagForm.requestSubmit();
          await window.__waitForTodoSaves();
          const renamed = document.querySelector('[data-todo-managed-tag-edit]').dataset.todoManagedTagEdit;
          document.querySelector('[data-todo-managed-tag-remove]').click();
          await window.__waitForTodoSaves();
          const restored = document.querySelector('[data-todo-managed-tag-edit]').dataset.todoManagedTagEdit;
          Object.defineProperty(window, 'localStorage', { configurable: true, value: storage });
          return [renamed, restored, JSON.parse(storage.getItem('codex-dashboard.todo-tags'))[0],
            JSON.parse(storage.getItem('codex-dashboard.todos')).items[0].tags[0],
            document.querySelector('[data-todo-storage-error]').hidden];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Work", "Work", "Work", "Work", false])
    }

    func testPendingAddDoesNotDuplicateItemOrEraseNextDraft() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const store = window.__todoStoreForTests;
          const originalSave = store.save;
          let releaseSave;
          const gate = new Promise(resolve => { releaseSave = resolve; });
          store.save = (...args) => gate.then(() => originalSave(...args));
          const form = document.querySelector('[data-todo-form]');
          const title = form.querySelector('[data-todo-new-title]');
          const body = form.querySelector('[data-todo-new-body]');
          const submit = form.querySelector('button[type="submit"]');
          title.value = 'First item';
          form.requestSubmit();
          title.value = 'Second draft';
          body.value = 'Keep these notes';
          form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
          const disabledWhileSaving = submit.disabled;
          store.save = originalSave;
          releaseSave();
          for (let attempt = 0; submit.disabled && attempt < 100; attempt += 1) {
            await new Promise(resolve => setTimeout(resolve, 10));
          }
          const afterFirstSave = [store.load().length, title.value, body.value, submit.disabled];
          form.requestSubmit();
          await window.__waitForTodoSaves();
          for (let attempt = 0; submit.disabled && attempt < 100; attempt += 1) {
            await new Promise(resolve => setTimeout(resolve, 10));
          }
          return [disabledWhileSaving, afterFirstSave,
            store.load().map(item => item.title), title.value, body.value];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? [AnyHashable], [1, "Second draft", "Keep these notes", false])
        XCTAssertEqual(values[2] as? [String], ["Second draft", "First item"])
        XCTAssertEqual(values[3] as? String, "")
        XCTAssertEqual(values[4] as? String, "")
    }

    func testDestroyAbortsPendingImageReaders() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const readers = [];
          window.FileReader = class extends EventTarget {
            readAsDataURL() { readers.push(this); }
            abort() { this.aborted = true; this.dispatchEvent(new Event('loadend')); }
          };
          const paste = new Event('paste', { bubbles: true, cancelable: true });
          Object.defineProperty(paste, 'clipboardData', { value: {
            files: [new File(['test'], 'test.png', { type: 'image/png' })],
          }});
          document.querySelector('[data-todo-new-title]').dispatchEvent(paste);
          window.__codexDashboard.destroy();
          return [readers.length, readers.every(reader => reader.aborted)];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [1, true])
    }

}
