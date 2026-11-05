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
  assert.equal(query.projectGitActionThread(candidates, projectGroupPath), assigned);
  assert.equal(query.projectGitActionThread([automation], projectGroupPath), automation);
  assert.equal(query.projectGitActionThread(candidates.slice(1, 4), projectGroupPath), undefined);
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
    assert.equal(state.changedProjects.size, expectedLabel ? 1 : 0, projectGitStatus);
    assert.equal(state.indicatedChangedProjectPaths.size, expectedLabel ? 1 : 0, projectGitStatus);
    assert.equal(selection.displayedThreads.length, expectedLabel ? 1 : 0, projectGitStatus);
    const markup = view.renderThreadList(selection.displayedThreads, {
      threads: [thread], changedProjects: state.changedProjects, filterMode: 'changedProjects', hiddenChangeIndicatorPaths: new Set(),
    });
    assert.equal(markup.includes('class="dashboard-git-changes"'), expectedLabel !== null, projectGitStatus);
    if (expectedLabel) {
      assert.ok(markup.includes(`<span>${expectedLabel}</span>`), projectGitStatus);
      const action = projectGitStatus === 'unpushedCommits' ? 'Push' : 'Commit';
      assert.equal(state.changedProjects.get('/project').action, action);
      assert.match(markup, new RegExp(`title="Open Codex’s ${action} flow for this project"><span>${action}</span>`));
    }
    assert.equal(query.summarizeActivity([{ ...thread, projectGroupPath: null }], () => false, new Set()).changedProjects.size, 0, projectGitStatus);
  }
});

test('Unread project actions can use an idle chat outside the visible group', () => {
  const project = { projectName: 'Project', projectGroupPath: '/project',
    projectGitStatus: 'unpushedCommits', sharesGroupRepository: true };
  const unread = { ...project, id: 'unread', runState: 'running' };
  const idle = { ...project, id: 'read', runState: 'idle' };
  const threads = [unread, idle];
  const state = query.summarizeActivity(threads, thread => thread === unread, new Set());
  const selection = query.selectThreads({
    threads, filterMode: 'unread', isThreadUnread: thread => thread === unread, visibleItemLimit: 10,
  });
  const markup = view.renderThreadList(selection.displayedThreads, {
    threads, changedProjects: state.changedProjects, filterMode: 'unread', collapsedProjectPaths: new Set(),
    hiddenChangeIndicatorPaths: new Set(), isUnread: thread => thread === unread,
  });
  assert.equal(query.projectGitActionThread(threads, '/project'), idle);
  assert.match(markup, /title="Open Codex’s Push flow for this project"><span>Push<\/span>/);
});

test('Git status is resolved once per project independently of the action chat', () => {
  let statusReads = 0;
  const projectGroupPath = '/project';
  const threads = ['running', 'idle', 'idle'].map((runState, index) => ({
    id: String(index), projectGroupPath, projectName: 'Project', runState,
    projectID: 'project', sharesGroupRepository: true,
    get projectGitStatus() {
      statusReads++;
      return 'unpushedCommits';
    },
  }));
  const state = query.summarizeActivity(threads, () => false, new Set());
  const markup = view.renderThreadList([threads[0]], {
    threads, changedProjects: state.changedProjects, filterMode: 'unread',
    collapsedProjectPaths: new Set(), hiddenChangeIndicatorPaths: new Set(),
    isUnread: () => true,
  });
  assert.equal(statusReads, 1);
  assert.equal(query.projectGitActionThread(threads, projectGroupPath), threads[1]);
  assert.match(markup, /<span>Unpushed<\/span>/);
  assert.match(markup, /title="Open Codex’s Push flow for this project"/);
});

test('Project paths retain trailing spaces for counts, paging, grouping, actions, and preferences', () => {
  const threads = ['/project', '/project '].map((projectGroupPath, index) => ({
    id: String(index), projectGroupPath, projectName: 'Project', runState: 'idle',
    projectID: String(index), sharesGroupRepository: true, projectGitStatus: 'uncommittedChanges',
  }));
  const hidden = new Set(['/project ']);
  const state = query.summarizeActivity(threads, () => true, hidden);
  assert.deepEqual(Array.from(state.changedProjects.keys()), ['/project', '/project ']);
  assert.deepEqual(Array.from(state.indicatedChangedProjectPaths), ['/project']);
  const firstPage = query.selectThreads({
    threads, ...state, filterMode: 'changedProjects', visibleItemLimit: 1,
  });
  assert.deepEqual(Array.from(firstPage.displayedThreads, thread => thread.id), ['0']);
  assert.equal(firstPage.hasMore, true);
  const selection = query.selectThreads({
    threads, ...state, filterMode: 'changedProjects', visibleItemLimit: 2,
  });
  assert.equal(selection.hasMore, false);
  assert.equal(query.projectGitActionThread(threads, '/project '), threads[1]);
  const markup = view.renderThreadList(selection.displayedThreads, {
    threads, changedProjects: state.changedProjects, filterMode: 'changedProjects',
    hiddenChangeIndicatorPaths: hidden,
  });
  assert.equal((markup.match(/data-dashboard-git-project=/g) || []).length, 2);
  assert.match(markup, /data-project-indicators="\/project "/);
  assert.match(markup, /data-project-git-action="\/project "/);
  const unreadMarkup = view.renderThreadList(threads, {
    threads, changedProjects: state.changedProjects, filterMode: 'unread',
    collapsedProjectPaths: new Set(['/project ']), hiddenChangeIndicatorPaths: hidden,
    isUnread: () => true,
  });
  assert.match(unreadMarkup, /class="dashboard-project-group is-collapsed" data-dashboard-project-group="\/project "/);
  assert.equal((unreadMarkup.match(/class="dashboard-project-group/g) || []).length, 2);

  let saved;
  const preferences = vm.runInNewContext(`${resource('chat-overview-preferences.js')}\nchatOverviewPreferences`, {
    localStorage: { getItem: () => saved, setItem: (_, value) => { saved = value; } },
  });
  preferences.savePreferences({
    filterMode: 'unread', collapsedProjectPaths: new Set(['/project ']), hiddenChangeIndicatorPaths: hidden,
  });
  const loaded = preferences.loadPreferences();
  assert.deepEqual(Array.from(loaded.collapsedProjectPaths), ['/project ']);
  assert.deepEqual(Array.from(loaded.hiddenChangeIndicatorPaths), ['/project ']);
});


test('Unavailable Git actions retain their explanations', () => {
  for (const [runState, sharesGroupRepository, label] of [
    ['running', true, 'Chat running'],
    ['idle', false, 'No repository chat'],
  ]) {
    const thread = { id: 'chat', projectName: 'Project', projectGroupPath: '/project',
      projectGitStatus: 'unpushedCommits', runState, sharesGroupRepository };
    const state = query.summarizeActivity([thread], () => false, new Set());
    const markup = view.renderThreadList([thread], {
      threads: [thread], changedProjects: state.changedProjects, filterMode: 'changedProjects',
      hiddenChangeIndicatorPaths: new Set(),
    });
    assert.match(markup, /title="Push requires an idle chat in this project’s repository" disabled/);
    assert.ok(markup.includes(`<span>${label}</span>`));
  }
});
