const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Todos/todo-composer-actions.js'), 'utf8');

function harness({ missingEditor = false, presetFails = false, newChat = false, runTransfer } = {}) {
  const item = { id: 'todo', title: 'Review release', project: { id: 'project' },
    preset: presetFails ? { model: 'example' } : null };
  const thread = { id: 'thread', title: 'Release' };
  const notice = { hidden: true, textContent: '' };
  const warnings = [];
  const composer = { innerText: '', closest: () => null,
    parentElement: { append: warning => warnings.push(warning) } };
  const select = { hidden: true, value: '', replaceChildren() {}, focus() {} };
  const button = { setAttribute() {} };
  const row = { querySelector: selector => selector === '[data-todo-paste-thread]' ? select : button };
  let opens = 0;
  let clock = 0;
  const context = {
    document: {
      body: { append: warning => warnings.push(warning) },
      querySelector: selector => selector === '[data-todo-composer-error]' ? notice : null,
      createElement: () => ({ dataset: {}, setAttribute() {} }),
    },
    Option: function (label, value) { this.label = label; this.value = value; },
    performance: { now: () => clock += 600 },
    dashboardElements: { elementIDs: { promptDialog: 'prompts' } },
    codexUIContracts: {
      composer: () => missingEditor ? null : composer,
      projects: () => [item.project],
      activeComposerThreadID: () => newChat ? null : thread.id,
      activeComposerProjectID: () => item.project.id,
      isThreadSelected: () => true,
    },
    codexHost: { navigateToThread() {}, newChat: async () => true },
    domUtils: {
      waitFor: async predicate => predicate() || predicate(),
      delay: async () => {},
    },
    todoImageStore: { load: async items => items },
    composerModelPicker: { applyPreset: async () => !presetFails },
    composerAdapter: { insert: content => { composer.innerText = content; return true; } },
  };
  const create = vm.runInNewContext(`${source}\ncreateTodoComposerActions`, context);
  const actions = create({ isDestroyed: () => false,
    pageState: { open: () => opens++, close() {} },
    threadReferencesForProject: () => [thread], getItems: () => [item], runTransfer });
  return { item, notice, warnings, composer, get opens() { return opens; },
    async paste() {
      actions.chooseTodoThread(item, row);
      select.value = thread.id;
      select.onchange();
      await new Promise(resolve => setImmediate(resolve));
    },
    openNewChat: () => actions.openTodoInNewThread(item),
  };
}

test('both transfer entry points use the supplied operation runner', async () => {
  let transfers = 0;
  const runTransfer = operation => { transfers++; return operation(); };
  await harness({ newChat: true, runTransfer }).openNewChat();
  await harness({ runTransfer }).paste();
  assert.equal(transfers, 2);
});

for (const failure of [{ missingEditor: true }, { presetFails: true }]) {
  test(`existing-chat failure opens To-dos once: ${Object.keys(failure)[0]}`, async () => {
    const state = harness(failure);
    await state.paste();
    assert.equal(state.opens, 1);
    assert.equal(state.notice.hidden, false);
    assert.equal(state.notice.textContent,
      'Could not paste this to-do. Check the chat editor and model settings, then try again.');
    assert.equal(state.composer.innerText, '');
    assert.equal(state.warnings.length, 0);
  });
}

test('new-chat preset failure keeps inserted text and warns in the chat', async () => {
  const state = harness({ presetFails: true, newChat: true });
  await state.openNewChat();
  assert.equal(state.opens, 0);
  assert.equal(state.composer.innerText, state.item.title);
  assert.equal(state.warnings.length, 1);
  assert.equal(state.warnings[0].textContent,
    'Could not apply this to-do’s model settings. Check the model, reasoning effort, and speed before sending.');
});

test('new-chat missing editor warns without reopening To-dos', async () => {
  const state = harness({ missingEditor: true, newChat: true });
  await state.openNewChat();
  assert.equal(state.opens, 0);
  assert.equal(state.warnings.length, 1);
  assert.equal(state.warnings[0].textContent,
    'Could not find the new chat editor. Return to To-dos and try again.');
});
