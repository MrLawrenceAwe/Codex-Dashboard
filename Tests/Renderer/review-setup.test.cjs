const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Reviews/review-loop-setup-view.js'), 'utf8');

// Model form metadata only; no browser, DOM implementation, or UI is launched.
function setup() {
  class Control {
    value = '';
    disabled = false;
    hidden = false;
    checked = false;
    options = [];
    set innerHTML(markup) {
      this.markup = markup;
      this.options = [...markup.matchAll(/<option value="([^"]*)">([^<]*)<\/option>/g)]
        .map(([, value, textContent]) => ({ value, textContent }));
      if (this.options.length) this.value = this.options[0].value;
    }
    get innerHTML() { return this.markup; }
    add(option) { this.options.push(option); }
    querySelector(selector) {
      return selector.startsWith('option') ? this.options.find(option => option.value === 'false') : this.input;
    }
  }
  const controls = new Map();
  const get = selector => {
    if (!controls.has(selector)) controls.set(selector, new Control());
    return controls.get(selector);
  };
  for (const [label, field] of [
    ['.review-live-testing', '[data-review-live-testing]'],
    ['.review-extension', '[data-review-extension]'],
    ['.review-preserve-ui-copy', '[data-review-preserve-ui-copy]'],
    ['.review-mute-test-playback', '[data-review-mute-test-playback]'],
    ['.review-project-context', '[data-review-prompt-context]'],
  ]) get(label).input = get(field);
  get('[data-review-push]').innerHTML = '<option value="false">Keep commits local</option>';
  get('[data-review-limit]').value = '5';
  const root = {
    querySelector: get,
    querySelectorAll: () => [...controls].filter(([selector]) => selector.startsWith('[data-')).map(([, control]) => control),
  };
  const view = vm.runInNewContext(`${source}\nreviewLoopSetupView`, {
    domUtils: { escapeHTML: value => value },
    composerPresets: { reasoningLabel: value => value },
    document: { querySelector: () => root },
    Option: function (textContent, value) { Object.assign(this, { textContent, value }); },
  });
  const snapshot = {
    projects: [{ id: 'alias', name: 'Alias', path: '/tmp/alias', requiresQueue: true, workspaceKind: 'git' }],
    models: [{ modelID: 'available', displayName: 'Available', supportedReasoningEfforts: ['high'] }],
    reviewTypes: [{ id: 'bugs', usesPriorities: true, supportsLiveTesting: true, supportsProjectContext: true }],
  };
  return { view, get, snapshot };
}

test('native queue eligibility drives annotations, button labels, and submissions together', () => {
  const { view, get, snapshot } = setup();
  view.render(snapshot, null);
  assert.match(get('[data-review-project]').options[0].textContent, /Queue available/);
  assert.match(get('[data-review-start]').innerHTML, /^Queue review/);
  assert.equal(view.readSettings().kind, 'queue');
  snapshot.projects[0].requiresQueue = false;
  view.render(snapshot, null);
  assert.doesNotMatch(get('[data-review-project]').options[0].textContent, /Queue available/);
  assert.match(get('[data-review-start]').innerHTML, /^Start review/);
  assert.equal(view.readSettings().kind, 'start');
});

test('model removal and repeated snapshots keep reasoning controls disabled', () => {
  const { view, get, snapshot } = setup();
  view.render(snapshot, null);
  const model = get('[data-review-model]');
  const effort = get('[data-review-effort]');
  model.value = 'available';
  view.renderReasoningOptions();
  assert.equal(effort.disabled, false);
  effort.value = 'high';
  snapshot.models = [];
  view.render(snapshot, null);
  assert.equal(model.value, 'available');
  assert.equal(effort.disabled, true);
  assert.equal(effort.value, '');
  view.render(snapshot, { kind: 'start' });
  view.render(snapshot, null);
  assert.equal(effort.disabled, true);
  snapshot.models = [{ modelID: 'available', supportedReasoningEfforts: ['high'] }];
  view.render(snapshot, null);
  assert.equal(effort.disabled, false);
});

test('folder and pending restrictions survive model changes and acknowledgement', () => {
  const { view, get, snapshot } = setup();
  snapshot.projects[0].workspaceKind = 'folder';
  view.render(snapshot, null);
  get('[data-review-model]').value = 'available';
  view.renderReasoningOptions();
  assert.equal(get('[data-review-push]').disabled, true);
  view.render(snapshot, { kind: 'queue' });
  assert.equal(get('[data-review-effort]').disabled, true);
  view.render(snapshot, null);
  assert.equal(get('[data-review-effort]').disabled, false);
  assert.equal(get('[data-review-push]').disabled, true);
  snapshot.projects = [];
  view.render(snapshot, null);
  assert.equal(get('[data-review-start]').disabled, true);
  assert.equal(get('[data-review-effort]').disabled, true);
});
