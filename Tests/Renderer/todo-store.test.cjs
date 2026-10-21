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
