const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const root = path.join(__dirname, '../../Sources/CodexDashboard/Resources/Dashboard');
const context = {
  crypto: require('node:crypto').webcrypto,
  COMPOSER_PRESET_SCHEMA: {
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
    speeds: ['standard', 'fast'],
  },
};
const store = vm.runInNewContext(
  fs.readFileSync(path.join(root, 'Composer/composer-presets.js'), 'utf8') + '\n' +
  fs.readFileSync(path.join(root, 'Todos/todo-store.js'), 'utf8') + '\ntodoStore', context,
);
const plain = value => JSON.parse(JSON.stringify(value));

test('complete draft construction normalises all assignments and creates its own identity', () => {
  const draft = {
    id: 'caller-id', createdAt: 1, updatedAt: 1,
    title: '  Follow up  ', body: '  Details  ', tags: [' Work ', 'work'],
    project: { id: ' project ', name: ' Project ' },
    thread: { id: ' chat ', title: ' Chat ' },
    preset: { model: 'chosen-model', reasoningEffort: 'high', speed: 'fast', extra: true },
    image: { dataURL: 'data:image/png;base64,AAAA', name: ' Image ', size: 3 },
  };
  const item = store.create(draft);
  assert.notEqual(item.id, draft.id);
  assert.ok(item.createdAt > draft.createdAt);
  assert.equal(item.updatedAt, item.createdAt);
  assert.equal(item.title, 'Follow up');
  assert.equal(item.body, 'Details');
  assert.deepEqual(plain(item.tags), ['Work']);
  assert.deepEqual(plain(item.project), { id: 'project', name: 'Project' });
  assert.deepEqual(plain(item.thread), { id: 'chat', title: 'Chat' });
  assert.deepEqual(plain(item.preset), { model: 'chosen-model', reasoningEffort: 'high', speed: 'fast' });
  assert.equal(item.image.type, 'image/png');
  assert.ok(item.image.storageKey.startsWith(item.id + ':'));
  assert.equal(draft.project.id, ' project ');
});

test('minimal and invalid drafts keep the store validation contract', () => {
  const item = store.create({ title: 'Minimal', project: { id: 'missing-name' },
    thread: { title: 'missing-id' }, preset: { reasoningEffort: 'unknown' } });
  assert.equal(item.body, '');
  assert.equal(item.completed, false);
  assert.deepEqual(plain(item.tags), []);
  for (const field of ['project', 'thread', 'preset', 'image']) assert.equal(item[field], null);
  assert.equal(store.create({ title: '   ', project: { id: 'p', name: 'P' } }), null);
});

test('text-only saves reuse image validation while changed bytes are revalidated', async () => {
  const values = new Map();
  const sandbox = vm.createContext({
    ...context,
    navigator: {},
    localStorage: {
      getItem: key => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, value),
      removeItem: key => values.delete(key),
    },
    todoImageStore: { persist: async () => {}, prune: async () => {} },
  });
  vm.runInContext(`
    globalThis.imageScans = 0;
    const originalMatch = String.prototype.match;
    String.prototype.match = function(pattern) {
      if (this.startsWith('data:')) imageScans++;
      return originalMatch.call(this, pattern);
    };
  `, sandbox);
  const cachedStore = vm.runInContext(
    fs.readFileSync(path.join(root, 'Composer/composer-presets.js'), 'utf8') + '\n' +
    fs.readFileSync(path.join(root, 'Todos/todo-store.js'), 'utf8') + '\ntodoStore', sandbox,
  );
  const image = { dataURL: 'data:image/png;base64,' + 'A'.repeat(10000), name: 'Original' };
  const item = cachedStore.create({ title: 'Image', image });
  assert.equal(sandbox.imageScans, 1);
  const edited = cachedStore.normalizeItem({ ...item, title: 'Edited' });
  assert.equal(await cachedStore.save([edited], [], [item], []), true);
  assert.equal(await cachedStore.save([edited], [], [edited], []), true);
  assert.equal(sandbox.imageScans, 1, 'unchanged attachment bytes must not be scanned on saves');

  item.image.dataURL = 'data:image/jpeg;base64,BBBB';
  item.image.name = 'Changed';
  const changed = cachedStore.normalizeItem(item);
  assert.equal(sandbox.imageScans, 2);
  assert.equal(changed.image.type, 'image/jpeg');
  assert.equal(changed.image.name, 'Changed');
  assert.equal(changed.image.storageKey, item.image.storageKey);
  item.image.dataURL = 'invalid';
  assert.equal(cachedStore.normalizeImage(item.image), null);
  // A cached deferred-data result must not bypass strict attachment validation.
  const deferred = cachedStore.normalizeImage({ type: 'image/png', dataURL: '' }, true);
  assert.equal(cachedStore.normalizeImage(deferred), null);
});
