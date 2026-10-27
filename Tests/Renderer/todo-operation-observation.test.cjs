const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const bootstrap = fs.readFileSync(path.join(__dirname,
  '../CodexDashboardTests/Web/Fixtures/todo-bootstrap.js'), 'utf8');

function observation() {
  const window = {};
  const create = vm.runInNewContext(`${bootstrap}\ncreateTodoDependencies`, { window });
  const store = {};
  const imageStore = {};
  return { window, store, imageStore, dependencies: create({ store, imageStore }) };
}

test('save waiters include nested work and transfer waiters remain independent', async () => {
  const { window, store, imageStore, dependencies } = observation();
  assert.equal(dependencies.store, store);
  assert.equal(window.__todoStoreForTests, store);
  assert.equal(window.__todoImageStoreForTests, imageStore);
  let releaseSave, releaseNested, releaseTransfer;
  const save = new Promise(resolve => { releaseSave = resolve; });
  const nested = new Promise(resolve => { releaseNested = resolve; });
  const transfer = new Promise(resolve => { releaseTransfer = resolve; });
  assert.equal(dependencies.runSave(() => save), save);
  dependencies.runTransfer(() => transfer);
  let saved = false, transferred = false;
  void save.then(() => dependencies.runSave(() => nested));
  const savesFinished = window.__waitForTodoSaves().then(() => { saved = true; });
  const transfersFinished = window.__waitForTodoTransfers().then(() => { transferred = true; });
  releaseSave();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(saved, false);
  releaseNested();
  await savesFinished;
  assert.equal(transferred, false);
  releaseTransfer();
  await transfersFinished;
});

test('rejected operations are removed without orphaning a rejected cleanup promise', async () => {
  const { window, dependencies } = observation();
  let rejectSave;
  const failure = new Promise((_, reject) => { rejectSave = reject; });
  dependencies.runSave(() => failure);
  const waiting = assert.rejects(window.__waitForTodoSaves(), /failed/);
  rejectSave(new Error('failed'));
  await waiting;
  await window.__waitForTodoSaves();
});

test('the controller save runner waits through persistence and snapshot reconciliation', async () => {
  const { window, store, dependencies } = observation();
  let items = [], submit, releaseSave, transferRunner, loads = 0;
  const gate = new Promise(resolve => { releaseSave = resolve; });
  Object.assign(store, {
    load: () => { loads++; return items; },
    loadTags: () => [],
    writeProtectionReason: () => null,
    create: draft => ({ ...draft, id: 'saved', tags: [] }),
    save: async next => { await gate; items = next; return true; },
  });
  let rendered = [];
  Object.assign(window, { addEventListener() {} });
  const controllerSource = fs.readFileSync(path.join(__dirname,
    '../../Sources/CodexDashboard/Resources/Dashboard/Todos/todo-list-controller.js'), 'utf8');
  const create = vm.runInNewContext(`${controllerSource}\ncreateTodoList`, {
    window,
    document: { querySelector: () => null },
    dashboardElements: { elementIDs: {} },
    createPageVisibilityController: () => ({}),
    createTodoImageController: () => ({}),
    createTodoComposerActions: ({ runTransfer }) => { transferRunner = runTransfer; return {}; },
    createTodoTagController: () => ({}),
    createTodoFormController: ({ onSubmit }) => { submit = onSubmit; return {}; },
    createSidebarThreadTodoActions: () => ({ refresh() {} }),
    todoListView: { render: state => { rendered = state.items; } },
    todoTagView: { updateTagOptions() {}, updateManagedTags() {} },
    todoImageStore: { load: async items => items },
    todoImageView: { showHydratedImages() {} },
  });
  create({ ...dependencies, threadReferencesForProject: () => [], findThread: () => null });
  assert.equal(transferRunner, dependencies.runTransfer);
  const submission = submit({ title: 'Observe the real save' });
  let finished = false;
  const waiting = window.__waitForTodoSaves().then(() => { finished = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(finished, false);
  releaseSave();
  await waiting;
  assert.equal(loads, 2, 'the waiter includes reconciliation against the saved snapshot');
  assert.equal(await submission, true);
  assert.equal(items[0].title, 'Observe the real save');
  assert.equal(rendered[0], items[0]);
});
