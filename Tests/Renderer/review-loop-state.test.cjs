const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const resource = name => fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Reviews', name), 'utf8');

test('page retains a newly finished loop until closed and prunes removed loops', () => {
  let open = false;
  let retained;
  const page = vm.runInNewContext(`${resource('review-loop-page.js')}\nreviewLoopPage`, {
    dashboardElements: { elementIDs: {} },
    createPageVisibilityController: () => ({
      open: () => { open = true; return true; },
      close: () => { open = false; },
      isOpen: () => open,
    }),
    reviewLoopView: { render: (_snapshot, _pending, ids) => { retained = [...ids]; } },
  });
  const loop = { id: 'loop', phase: 'running', isFinished: false };
  page.applySnapshot({ loops: [loop] });
  assert.deepEqual(retained, []);
  page.open();
  assert.deepEqual(retained, ['loop']);
  loop.phase = 'completed';
  loop.isFinished = true;
  page.applySnapshot({ loops: [loop] });
  assert.deepEqual(retained, ['loop']);
  page.close();
  page.open();
  assert.deepEqual(retained, []);
  loop.phase = 'running';
  loop.isFinished = false;
  page.applySnapshot({ loops: [loop] });
  assert.deepEqual(retained, ['loop']);
  page.applySnapshot({ loops: [] });
  assert.deepEqual(retained, []);
});

test('navigation counts terminal loops only while retained on the current board', () => {
  const markers = Object.fromEntries(['running', 'blocked', 'done'].map(kind => [kind, {
    hidden: true,
    attributes: {},
    count: { textContent: '' },
    setAttribute(name, value) { this.attributes[name] = value; },
    querySelector() { return this.count; },
  }]));
  const view = vm.runInNewContext(`${resource('review-loop-view.js')}\nreviewLoopView`, {
    domUtils: { escapeHTML: value => value },
    document: { querySelector: selector => markers[selector.match(/navigation-(\w+)/)[1]] },
  });
  const snapshot = { loops: [
    { id: 'running', phase: 'running', isFinished: false },
    { id: 'blocked', phase: 'blocked', isFinished: false },
    { id: 'done', phase: 'completed', isFinished: true },
    { id: 'stopped', phase: 'stopped', isFinished: true },
  ] };
  view.renderNavigationStatus(snapshot);
  assert.equal(markers.running.count.textContent, '1');
  assert.equal(markers.blocked.count.textContent, '1');
  assert.equal(markers.done.count.textContent, '0');
  assert.equal(markers.done.hidden, true);
  view.renderNavigationStatus(snapshot, new Set(['done', 'stopped']));
  assert.equal(markers.done.count.textContent, '1');
  assert.equal(markers.done.hidden, false);
  assert.equal(markers.done.attributes['aria-label'], '1 done (completed or round limit reached) review loop');
  view.renderNavigationStatus({ loops: [] });
  assert.equal(markers.running.hidden, true);
  assert.equal(markers.blocked.hidden, true);
  assert.equal(markers.done.hidden, true);
});
