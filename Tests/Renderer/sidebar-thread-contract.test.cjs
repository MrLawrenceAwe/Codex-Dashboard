const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Core/codex-ui-contracts.js'), 'utf8');

// Exercise host metadata and mutation records without launching a DOM or UI.
class ThreadNode {
  constructor(attributes = {}, children = [], text = '', tagName = 'span') {
    this.attributes = attributes;
    this.childNodes = children;
    this.text = text;
    this.tagName = tagName;
    for (const child of children) child.parentElement = this;
  }
  get textContent() { return this.text + this.childNodes.map(child => child.textContent).join(''); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  matches(selector) {
    return selector.split(',').some(choice => {
      const value = choice.trim();
      return value.startsWith('[')
        ? Object.hasOwn(this.attributes, value.slice(1, -1)) : this.tagName === value;
    });
  }
  closest(selector) {
    return this.matches(selector) ? this : this.parentElement?.closest(selector) || null;
  }
  querySelector(selector) {
    for (const child of this.childNodes) {
      if (!(child instanceof ThreadNode)) continue;
      if (child.matches(selector)) return child;
      const nested = child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }
}
const contract = vm.runInNewContext(`${source}\ncodexUIContracts.sidebarThreads`, {
  domUtils: {}, Element: ThreadNode,
});
const row = (id = 'local:chat-1', children = []) => new ThreadNode({
  'data-app-action-sidebar-thread-id': id,
}, children);

test('local IDs exclude remote, missing, and empty thread identities', () => {
  assert.equal(contract.localID(row()), 'chat-1');
  for (const node of [null, new ThreadNode(), row('remote:chat-1'), row('local:')]) {
    assert.equal(contract.localID(node), null);
  }
});

test('title lookup supports host title markers and plain rows without action labels', () => {
  for (const attribute of ['data-thread-title-trigger', 'data-marquee-text']) {
    const title = new ThreadNode({ [attribute]: '' }, [], ' Host title ');
    const thread = row('local:chat-1', [new ThreadNode({}, [title])]);
    assert.equal(contract.title(thread), 'Host title');
    assert.equal(contract.titleElement(thread), attribute === 'data-thread-title-trigger' ? title : null);
  }
  const thread = row('local:chat-1', [
    { textContent: ' Plain title ' },
    new ThreadNode({}, [], 'Menu', 'button'),
    new ThreadNode({}, [], 'Icon', 'svg'),
  ]);
  assert.equal(contract.title(thread), 'Plain title');
});

test('thread mutations recognise nested insertions, removals, and changes within a row', () => {
  const title = new ThreadNode({ 'data-thread-title-trigger': '' }, [], 'Title');
  const thread = row('local:chat-1', [title]);
  const wrapper = new ThreadNode({}, [thread]);
  for (const [addedNodes, removedNodes] of [[[wrapper], []], [[], [wrapper]]]) {
    assert.equal(contract.changedIn([{ type: 'childList', addedNodes, removedNodes }]), true);
  }
  for (const target of [title, { parentElement: title }]) {
    assert.equal(contract.changedIn([{ type: 'childList', target, addedNodes: [], removedNodes: [] }]), true);
  }
  for (const attributeName of contract.observedAttributes) {
    assert.equal(contract.changedIn([{ type: 'attributes', target: thread, attributeName }]), true);
  }
  assert.equal(contract.changedIn([{ type: 'attributes', target: wrapper, attributeName: 'class' }]), false);
  assert.equal(contract.changedIn([{ type: 'childList', target: new ThreadNode(),
    addedNodes: [new ThreadNode()], removedNodes: [] }]), false);
});
