const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const resource = name => fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Threads', name), 'utf8');
const query = vm.runInNewContext(`${resource('chat-overview-query.js')}\nchatOverviewQuery`);

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
  const view = vm.runInNewContext(`${resource('chat-overview-list-view.js')}\nchatOverviewListView`, {
    chatOverviewQuery: query,
    domUtils: { escapeHTML: String },
    dashboardIcons: { render: () => '' },
  });
  for (const [projectGitStatus, expectedLabel] of [
    ['notRepository', null],
    ['unavailable', null],
    ['clean', null],
    ['uncommittedChanges', 'Uncommitted'],
    ['uncommittedChangesWithoutRemote', 'Uncommitted'],
    ['unpushedCommits', 'Unpushed'],
    ['uncommittedChangesAndUnpushedCommits', 'Uncommitted · Unpushed'],
  ]) {
    const thread = { id: 'chat', projectName: 'Project', projectGroupPath: '/project', projectGitStatus };
    const state = query.summarizeActivity([thread], () => false, new Set());
    const selection = query.selectThreads({ threads: [thread], ...state,
      filterMode: 'changedProjects', visibleItemLimit: 10 });
    assert.equal(state.allChangedProjectPaths.size, expectedLabel ? 1 : 0, projectGitStatus);
    assert.equal(state.indicatedChangedProjectPaths.size, expectedLabel ? 1 : 0, projectGitStatus);
    assert.equal(selection.displayedThreads.length, expectedLabel ? 1 : 0, projectGitStatus);
    const markup = view.renderThreadList(selection.displayedThreads, {
      filterMode: 'changedProjects', hiddenChangeIndicatorPaths: new Set(),
    });
    assert.equal(markup.includes('class="dashboard-git-changes"'), expectedLabel !== null, projectGitStatus);
    if (expectedLabel) assert.ok(markup.includes(`<span>${expectedLabel}</span>`), projectGitStatus);
    assert.equal(query.hasPendingGitChanges({ ...thread, projectGroupPath: null }), false, projectGitStatus);
  }
});
