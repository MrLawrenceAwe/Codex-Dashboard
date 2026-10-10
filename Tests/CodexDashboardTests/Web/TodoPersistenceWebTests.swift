import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoPersistenceWebTests: SerializedDashboardWebTestCase {
    func testTextSavePreservesRowControlsAndFocusUntilNextAction() async throws {
        for field in ["title", "body"] {
            let view = try await webView()
            let result = try await view.evaluateAsyncJavaScript("""
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Saved title';
              form.requestSubmit();
              await window.__waitForTodoSaves();
              const editor = document.querySelector('[data-todo-\(field)]');
              const nextEditor = document.querySelector('[data-todo-\(field == "title" ? "body" : "title")]');
              const checkbox = document.querySelector('[data-todo-completed]');
              editor.focus();
              editor.value = 'Updated text';
              editor.dispatchEvent(new Event('change', { bubbles: true }));
              nextEditor.focus();
              await window.__waitForTodoSaves();
              const controlsPreserved = checkbox.isConnected && nextEditor.isConnected
                && document.activeElement === nextEditor;
              checkbox.click();
              await window.__waitForTodoSaves();
              const saved = window.__todoStoreForTests.load()[0];
              return [controlsPreserved, saved['\(field)'], saved.completed];
            })()
            """) as? [AnyHashable]
            XCTAssertEqual(result, [true, "Updated text", true], field)
        }
    }

    func testEmptyTitleRestoresSavedTextWithoutReplacingControls() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          form.querySelector('[data-todo-new-title]').value = 'Keep this title';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          const title = document.querySelector('[data-todo-title]');
          const checkbox = document.querySelector('[data-todo-completed]');
          title.value = '   ';
          title.dispatchEvent(new Event('change', { bubbles: true }));
          return [title.value, checkbox.isConnected, window.__todoStoreForTests.load()[0].title];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Keep this title", true, "Keep this title"])
    }

    func testLegacyLightPresetMigratesAndSurvivesFailedRewrite() async throws {
        let view = try await webView()
        let result = try await view.evaluateJavaScript("""
        (() => {
          const key = 'codex-dashboard.todos';
          const legacy = JSON.stringify({version:8,items:[{id:'saved',title:'Keep me',
            preset:{model:'gpt-future',reasoningEffort:'light',speed:'fast'},createdAt:1,updatedAt:2}]});
          localStorage.setItem(key, legacy);
          const nativeSet = Storage.prototype.setItem;
          Storage.prototype.setItem = function() { throw new Error('Storage full'); };
          let loaded;
          try { loaded = window.__todoStoreForTests.load(); }
          finally { Storage.prototype.setItem = nativeSet; }
          const preserved = localStorage.getItem(key) === legacy;
          window.__todoStoreForTests.load();
          const rewritten = JSON.parse(localStorage.getItem(key));
          return [preserved,loaded[0].preset.reasoningEffort,rewritten.version,
            rewritten.items[0].title,rewritten.items[0].preset.model,
            rewritten.items[0].preset.reasoningEffort,rewritten.items[0].createdAt];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, "low", 9, "Keep me", "gpt-future", "low", 1])
    }

    func testPersistenceInstrumentationRejectsMissingAndDuplicateAnchors() throws {
        XCTAssertThrowsError(try DashboardWebTestHarness.instrumentSource(
            "source without anchor", anchor: "instrument here", replacement: "tracked"))
        XCTAssertThrowsError(try DashboardWebTestHarness.instrumentSource(
            "instrument here; instrument here", anchor: "instrument here", replacement: "tracked"))
        XCTAssertEqual(try DashboardWebTestHarness.instrumentSource(
            "before instrument here after", anchor: "instrument here", replacement: "tracked"),
            "before tracked after")
    }

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

    func testSharedStorageUpdatesPreserveActiveTodoEditsAndMergeOnCommit() async throws {
        for field in ["title", "body"] {
            let view = try await webView()
            let result = try await view.evaluateAsyncJavaScript("""
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Saved title';
              form.querySelector('[data-todo-new-body]').value = 'Saved body';
              form.requestSubmit();
              await window.__waitForTodoSaves();
              const field = '\(field)';
              const otherField = field === 'title' ? 'body' : 'title';
              const editor = document.querySelector(`[data-todo-${field}]`);
              editor.focus();
              editor.value = 'Draft being typed';
              editor.setSelectionRange(5, 10);
              editor.dispatchEvent(new Event('input', { bubbles: true }));
              const key = 'codex-dashboard.todos';
              const oldValue = localStorage.getItem(key);
              const doc = JSON.parse(oldValue);
              doc.items[0][otherField] = 'Updated in another window';
              const newValue = JSON.stringify(doc);
              localStorage.setItem(key, newValue);
              window.dispatchEvent(new StorageEvent('storage', { key, oldValue, newValue }));
              localStorage.setItem('codex-dashboard.todo-tags', JSON.stringify(['Remote tag']));
              window.dispatchEvent(new StorageEvent('storage', { key: 'codex-dashboard.todo-tags' }));
              const preserved = editor.isConnected && document.activeElement === editor
                && editor.value === 'Draft being typed'
                && editor.selectionStart === 5 && editor.selectionEnd === 10;
              editor.dispatchEvent(new Event('change', { bubbles: true }));
              editor.blur();
              await window.__waitForTodoSaves();
              const saved = window.__todoStoreForTests.load()[0];
              return [preserved, saved[field], saved[otherField],
                document.querySelector(`[data-todo-${field}]`).value,
                window.__todoStoreForTests.loadTags().includes('Remote tag')];
            })()
            """) as? [AnyHashable]
            XCTAssertEqual(result, [true, "Draft being typed", "Updated in another window", "Draft being typed", true], field)
        }
    }

    func testStaleTodoEditPreservesConcurrentDeletionAndNewItems() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const deleted = store.create('Delete in another window');
          const survivor = store.create('Keep this task');
          const base = [deleted, survivor];
          await store.save(base, [], [], []);
          await store.save([{ ...survivor, body: 'Remote notes' }], [], base, []);
          const added = store.create('New local task');
          const saved = await store.save([
            { ...deleted, title: 'Stale edit' }, survivor, added,
          ], [], base, []);
          const items = store.load();
          return [saved, !items.some(item => item.id === deleted.id),
            items.some(item => item.id === added.id),
            items.find(item => item.id === survivor.id).body, items.length];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, true, true, "Remote notes", 2])
    }

    func testDeferredStorageRefreshRunsWhenTodoEditorLosesFocusWithoutAChange() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          form.querySelector('[data-todo-new-title]').value = 'Saved title';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          const editor = document.querySelector('[data-todo-title]');
          editor.focus();
          editor.value = 'Temporary draft';
          const key = 'codex-dashboard.todos';
          const doc = JSON.parse(localStorage.getItem(key));
          doc.items[0].body = 'Remote notes';
          localStorage.setItem(key, JSON.stringify(doc));
          window.dispatchEvent(new StorageEvent('storage', { key }));
          const preserved = editor.isConnected && editor.value === 'Temporary draft';
          editor.value = 'Saved title';
          editor.blur();
          await Promise.resolve();
          return [preserved, document.querySelector('[data-todo-body]').value];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, "Remote notes"])
    }

    func testLegacyTodoDocumentsMigrateWithoutLosingProjectsTagsOrImages() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const results = [];
          for (const version of [1, 2, 3, 4, 5, 6, 7]) {
            localStorage.clear();
            const project = { id: 'project-a', name: 'Project A' };
            const image = { dataURL: 'data:image/png;base64,aA==', type: 'image/png', size: 1, name: 'test.png' };
            const item = { id: 'todo-a', title: 'Saved task', image, createdAt: 1, updatedAt: 2 };
            if (version === 6) item.chat = { id: 'linked', title: 'Linked task' };
            Object.assign(item, version < 4 ? { badges: ['Work'], projectBadge: project }
              : version === 4 ? { tags: ['Work'], projectTag: project }
              : { tags: ['Work'], project });
            localStorage.setItem('codex-dashboard.todos', JSON.stringify({ version, items: [item] }));
            localStorage.setItem('codex-dashboard.todo-badges', JSON.stringify(['Personal']));
            const loaded = store.load();
            const tags = store.loadTags(loaded);
            const migrated = JSON.parse(localStorage.getItem('codex-dashboard.todos'));
            results.push(migrated.version === 9 && loaded[0].project.id === 'project-a'
              && loaded[0].tags[0] === 'Work' && loaded[0].image.dataURL === image.dataURL
              && loaded[0].createdAt === 1 && loaded[0].updatedAt === 2
              && tags.includes('Personal') && tags.includes('Work')
              && localStorage.getItem('codex-dashboard.todo-badges') === null
              && !Object.hasOwn(migrated.items[0], 'projectTag')
              && !Object.hasOwn(migrated.items[0], 'projectBadge')
              && !Object.hasOwn(migrated.items[0], 'badges')
              && !Object.hasOwn(migrated.items[0], 'chat')
              && (version !== 6 || migrated.items[0].thread.id === 'linked'));
          }
          return results;
        })()
        """) as? [Bool]
        XCTAssertEqual(result, [true, true, true, true, true, true, true])
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
            JSON.stringify({ version: 10, items: [{ id: 'future', title: 'Keep me' }] }),
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
            version: 10, items: [{ id: 'future', title: 'Keep me' }],
          }));
          return true;
        })()
        """) as? Bool
        XCTAssertEqual(result, true)
        _ = try await view.evaluateJavaScript(try DashboardWebTestHarness.trackedTodoInjection(injection))
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

    func testQueuedCompletionUndoKeepsTheLatestAction() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          form.querySelector('[data-todo-new-title]').value = 'Undo completion';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          document.querySelector('[data-todo-filter="all"]').click();
          const images = window.__todoImageStoreForTests;
          const originalPersist = images.persist;
          let release;
          const gate = new Promise(resolve => { release = resolve; });
          images.persist = async items => { await gate; return originalPersist(items); };
          const complete = document.querySelector('[data-todo-completed]');
          complete.checked = true;
          complete.dispatchEvent(new Event('change', { bubbles: true }));
          const undo = document.querySelector('[data-todo-completed]');
          undo.checked = false;
          undo.dispatchEvent(new Event('change', { bubbles: true }));
          release();
          await window.__waitForTodoSaves();
          images.persist = originalPersist;
          return [window.__todoStoreForTests.load()[0].completed,
            document.querySelector('[data-todo-completed]').checked,
            document.querySelector('[data-todo-storage-error]').hidden];
        })()
        """) as? [Bool]
        XCTAssertEqual(result, [false, false, true])
    }

    func testQueuedEditRetainsEarlierChangesWhenTheFirstWriteFails() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          form.querySelector('[data-todo-new-title]').value = 'Original';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          const storage = window.localStorage;
          let failed = false;
          Object.defineProperty(window, 'localStorage', { configurable: true, value: {
            getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
            setItem(key, value) {
              if (key === 'codex-dashboard.todos' && !failed) {
                failed = true;
                throw new Error('First write failed');
              }
              storage.setItem(key, value);
            },
          }});
          const title = document.querySelector('[data-todo-title]');
          title.value = 'Edited title';
          title.dispatchEvent(new Event('change', { bubbles: true }));
          const body = document.querySelector('[data-todo-body]');
          body.value = 'Later notes';
          body.dispatchEvent(new Event('change', { bubbles: true }));
          await window.__waitForTodoSaves();
          Object.defineProperty(window, 'localStorage', { configurable: true, value: storage });
          const [saved] = window.__todoStoreForTests.load();
          return [failed, saved.title, saved.body,
            document.querySelector('[data-todo-storage-error]').hidden];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, "Edited title", "Later notes", true])
    }

    func testMergedInlineImageSurvivesAnUnrelatedSave() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const store = window.__todoStoreForTests;
          const images = window.__todoImageStoreForTests;
          const originalPersist = images.persist;
          let started, release;
          const startedGate = new Promise(resolve => { started = resolve; });
          const gate = new Promise(resolve => { release = resolve; });
          images.persist = async items => {
            started();
            await gate;
            return originalPersist(items);
          };
          const local = store.create('Local addition');
          const saving = store.save([local], [], [], []);
          await startedGate;
          // Another window falls back to inline storage while this save is pending.
          const image = { dataURL: 'data:image/png;base64,aA==', type: 'image/png', size: 1, name: 'inline.png' };
          const external = store.create('Other window image', '', image);
          localStorage.setItem(store.storageKey, JSON.stringify({ version: 9, items: [external] }));
          release();
          const saved = await saving;
          images.persist = originalPersist;
          const loaded = await images.load(store.load());
          return [saved, loaded.length,
            loaded.find(item => item.id === external.id).image.dataURL];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, 2, "data:image/png;base64,aA=="])
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
          const hydrated = await window.__todoImageStoreForTests.load(saved);
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
          const [restored] = await window.__todoImageStoreForTests.load(store.load());
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
          const [restored] = await window.__todoImageStoreForTests.load(store.load());
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
        _ = try await view.evaluateJavaScript(try DashboardWebTestHarness.trackedTodoInjection(injection))
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
        _ = try await view.evaluateJavaScript(try DashboardWebTestHarness.trackedTodoInjection(injection))
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

        _ = try await view.evaluateJavaScript(try DashboardWebTestHarness.trackedTodoInjection(injection))
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
