const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Core/codex-ui-contracts.js'), 'utf8');

// Minimal nodes exercise contract data and mutation records without a browser.
class ProjectNode {
  constructor(attributes = {}, children = []) {
    this.attributes = attributes;
    this.children = children;
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  matches(selector) {
    return [...selector.matchAll(/\[([^\]]+)\]/g)]
      .every(([, attribute]) => Object.hasOwn(this.attributes, attribute));
  }
  querySelector(selector) {
    return this.children.find(child => child.matches(selector) || child.querySelector(selector)) || null;
  }
}
const contract = vm.runInNewContext(`${source}\ncodexUIContracts.sidebarProjects`, {
  domUtils: {}, Element: ProjectNode,
});

const projectRow = () => new ProjectNode({
  'data-app-action-sidebar-project-row': '',
  'data-app-action-sidebar-project-id': 'project-1',
  'data-app-action-sidebar-project-label': 'Example',
});

test('sidebar project metadata and observed attributes share the host contract', () => {
  const row = projectRow();
  assert.equal(row.matches(contract.selector), true);
  assert.deepEqual({ ...contract.metadata(null) }, { id: '', name: '' });
  assert.deepEqual({ ...contract.metadata(row) }, { id: 'project-1', name: 'Example' });
  for (const attribute of Object.keys(row.attributes)) {
    assert.equal(contract.observedAttributes.includes(attribute), true);
    assert.equal(contract.changedIn([{ type: 'attributes', target: row, attributeName: attribute }]), true);
  }
});

test('project changes recognise nested insertions, removals, and new row markers', () => {
  const wrapper = new ProjectNode({}, [projectRow()]);
  for (const [addedNodes, removedNodes] of [[[wrapper], []], [[], [wrapper]]]) {
    assert.equal(contract.changedIn([{ type: 'childList', addedNodes, removedNodes }]), true);
  }
  assert.equal(contract.changedIn([{
    type: 'attributes', target: new ProjectNode(), attributeName: 'data-app-action-sidebar-project-row',
  }]), true);
  assert.equal(contract.changedIn([{
    type: 'childList', addedNodes: [new ProjectNode()], removedNodes: [],
  }]), false);
  assert.equal(contract.changedIn([{
    type: 'attributes', target: new ProjectNode(), attributeName: 'class',
  }]), false);
});
