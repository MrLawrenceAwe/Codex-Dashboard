const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

test('viewer launch preserves exact checkout, acknowledges matching request and expires', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../../Sources/CodexDashboard/Resources/Dashboard/ProjectViewer/project-viewer-launcher.js'), 'utf8');
  let expire;
  const api = vm.runInNewContext(`${source}\nprojectViewerLauncher`, {
    crypto: { getRandomValues: values => values.fill(1) },
    setTimeout: callback => { expire = callback; return 1; },
    clearTimeout() {},
  });
  assert.equal(api.open('../outside'), false);
  assert.equal(api.open('/project/worktree with spaces'), true);
  const request = JSON.parse(api.pending());
  assert.equal(request.path, '/project/worktree with spaces');
  assert.equal(api.acknowledge('other'), false);
  assert.equal(api.acknowledge(request.id), true);
  assert.equal(api.pending(), null);
  api.open('/project');
  expire();
  assert.equal(api.pending(), null);
  api.open('/project');
  api.destroy();
  assert.equal(api.pending(), null);
});
