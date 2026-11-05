const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const resource = name => fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Threads', name), 'utf8');
const query = vm.runInNewContext(`${resource('chat-overview-query.js')}\nchatOverviewQuery`);
const view = vm.runInNewContext(`${resource('chat-overview-list-view.js')}\nchatOverviewListView`, {
  chatOverviewQuery: query,
  domUtils: { escapeHTML: String },
  dashboardIcons: { render: () => '' },
});

test('Git actions prefer a project chat over newer projectless automation runs', () => {
  const projectGroupPath = '/Users/example/Job Search Companion';
  const thread = (id, overrides = {}) => ({ id, projectGroupPath, runState: 'idle',
    sharesGroupRepository: true, projectID: 'project', projectGitStatus: 'uncommittedChanges', ...overrides });
  const automation = thread('automation', { projectID: null });
  const assigned = thread('project-chat');
  const candidates = [automation,
    thread('running', { runState: 'running' }),
    thread('nested', { sharesGroupRepository: false }),
    thread('other-project', { projectGroupPath: '/other' }),
    assigned, thread('older-project-chat')];
  assert.equal(query.projectGitAction(candidates, projectGroupPath).thread, assigned);
  assert.equal(query.projectGitAction([automation], projectGroupPath).thread, automation);
  assert.equal(query.projectGitAction(candidates.slice(1, 4), projectGroupPath).thread, undefined);
});

test('Overview includes running chats before paged recent history without duplicates', () => {
  const threads = [
    { id: 'newer-idle', runState: 'idle' },
    { id: 'older-idle', runState: 'idle' },
    { id: 'oldest-running', runState: 'running' },
  ];
  const selection = query.selectThreads({ threads, filterMode: 'overview', visibleItemLimit: 1 });
  assert.deepEqual(Array.from(selection.displayedThreads, thread => thread.id), ['oldest-running', 'newer-idle']);
  assert.equal(selection.leadingRunningThreadCount, 1);
  assert.equal(selection.hasMore, true);
  assert.equal(selection.matchingThreads.length, 3);
});

test('Overview is the default and retains other saved preferences from the former filter', () => {
  for (const filterMode of [undefined, 'active', 'unknown', 'overview', 'unread', 'changedProjects']) {
    const stored = { filterMode, collapsedProjectPaths: ['/project'], hiddenChangeIndicatorPaths: ['/hidden'] };
    const preferences = vm.runInNewContext(`${resource('chat-overview-preferences.js')}\nchatOverviewPreferences`, {
      localStorage: { getItem: () => JSON.stringify(stored) },
    });
    const loaded = preferences.loadPreferences();
    assert.equal(loaded.filterMode, ['unread', 'changedProjects'].includes(filterMode) ? filterMode : 'overview');
    assert.deepEqual(Array.from(loaded.collapsedProjectPaths), ['/project']);
    assert.deepEqual(Array.from(loaded.hiddenChangeIndicatorPaths), ['/hidden']);
  }
});

test('Local changes counts, filtering, and labels agree for every Git status', () => {
  for (const [projectGitStatus, expectedLabel] of [
    ['notRepository', null],
    ['unavailable', null],
    ['clean', null],
    ['uncommittedChanges', 'Uncommitted'],
    ['unpushedCommits', 'Unpushed'],
    ['uncommittedChangesAndUnpushedCommits', 'Uncommitted · Unpushed'],
  ]) {
    const thread = { id: 'chat', projectName: 'Project', projectGroupPath: '/project', projectGitStatus, runState: 'idle', sharesGroupRepository: true };
    const state = query.summarizeActivity([thread], () => false, new Set());
    const selection = query.selectThreads({ threads: [thread], ...state,
      filterMode: 'changedProjects', visibleItemLimit: 10 });
    assert.equal(state.allChangedProjectPaths.size, expectedLabel ? 1 : 0, projectGitStatus);
    assert.equal(state.indicatedChangedProjectPaths.size, expectedLabel ? 1 : 0, projectGitStatus);
    assert.equal(selection.displayedThreads.length, expectedLabel ? 1 : 0, projectGitStatus);
    const markup = view.renderThreadList(selection.displayedThreads, {
      threads: [thread], filterMode: 'changedProjects', hiddenChangeIndicatorPaths: new Set(),
    });
    assert.equal(markup.includes('class="dashboard-git-changes"'), expectedLabel !== null, projectGitStatus);
    if (expectedLabel) {
      assert.ok(markup.includes(`<span>${expectedLabel}</span>`), projectGitStatus);
      const action = projectGitStatus === 'unpushedCommits' ? 'Push' : 'Commit';
      assert.equal(query.projectGitAction([thread], '/project').label, action);
      assert.match(markup, new RegExp(`title="Open Codex’s ${action} flow for this project"><span>${action}</span>`));
    }
    assert.equal(query.hasPendingGitChanges({ ...thread, projectGroupPath: null }), false, projectGitStatus);
  }
});

test('Unread project actions can use an idle chat outside the visible group', () => {
  const project = { projectName: 'Project', projectGroupPath: '/project',
    projectGitStatus: 'unpushedCommits', sharesGroupRepository: true };
  const unread = { ...project, id: 'unread', runState: 'running' };
  const idle = { ...project, id: 'read', runState: 'idle' };
  const threads = [unread, idle];
  const selection = query.selectThreads({
    threads, filterMode: 'unread', isThreadUnread: thread => thread === unread, visibleItemLimit: 10,
  });
  const markup = view.renderThreadList(selection.displayedThreads, {
    threads, filterMode: 'unread', collapsedProjectPaths: new Set(),
    hiddenChangeIndicatorPaths: new Set(), isUnread: thread => thread === unread,
  });
  assert.equal(query.projectGitAction(threads, '/project').thread, idle);
  assert.match(markup, /title="Open Codex’s Push flow for this project"><span>Push<\/span>/);
});
