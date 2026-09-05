const taskDashboard = (() => {
// Snapshots are sorted newest-first on arrival; lookups preserve that order.
let threads = [];
const storedPreferences = taskDashboardState.loadPreferences();
let filterMode = storedPreferences.filterMode;
const pageSize = 60;
let visibleLimit = pageSize;
const { collapsedProjects, ignoredProjectPaths } = storedPreferences;
let unreadSyncTimer;
let renderFrame;
let renderFallbackTimer;
let unreadMonitoringStarted = false;
const pageState = createDashboardPage({
  pageID: dashboardElements.elementIDs.page,
  navigationID: dashboardElements.elementIDs.navButton,
  rootClass: 'codex-dashboard-open',
});
let viewNeedsRender = true;
let unreadThreadIDs = new Set();
const sidebarUnreadOverrides = new Map();
const completedTickDuration = 60_000;
const completedTickExpiryByThreadID = new Map();
let completedTickTimer;
let commitOrPushError = '';

function savePreferences() {
  taskDashboardState.savePreferences({
    filterMode,
    collapsedProjects,
    ignoredProjectPaths,
  });
}

function unreadRevision(thread) {
  return JSON.stringify([
    thread.recencyEpochMillis, thread.runState, thread.latestLifecycleEventKind, thread.preview,
  ]);
}

function syncUnreadFromSidebar(nextUnreadThreadIDs = new Set(unreadThreadIDs)) {
  const readStates = codexHost.threadReadStates();
  readStates.forEach((isUnread, id) => {
    const thread = threads.find((item) => item.id === id);
    if (!thread) return;
    if (isUnread === (thread.isUnread === true)) sidebarUnreadOverrides.delete(id);
    else sidebarUnreadOverrides.set(id, { isUnread, revision: unreadRevision(thread) });
    if (isUnread) nextUnreadThreadIDs.add(id);
    else nextUnreadThreadIDs.delete(id);
  });
  return updateUnreadThreadIDs(nextUnreadThreadIDs);
}

function updateUnreadThreadIDs(nextUnreadThreadIDs) {
  let changed = false;
  unreadThreadIDs.forEach((threadID) => {
    if (nextUnreadThreadIDs.has(threadID)) return;
    changed = true;
    const thread = threads.find((item) => item.id === threadID);
    if (thread?.latestLifecycleEventKind === 'completed') {
      completedTickExpiryByThreadID.set(threadID, Date.now() + completedTickDuration);
    }
  });
  nextUnreadThreadIDs.forEach((threadID) => {
    if (!unreadThreadIDs.has(threadID)) changed = true;
    completedTickExpiryByThreadID.delete(threadID);
  });
  unreadThreadIDs = nextUnreadThreadIDs;
  scheduleCompletedTickExpiry();
  return changed;
}

function isCompletionTickVisible(thread) {
  if (thread.latestLifecycleEventKind !== 'completed') return false;
  if (isThreadUnread(thread)) return true;
  const expiry = completedTickExpiryByThreadID.get(thread.id);
  if (!expiry) return false;
  if (expiry > Date.now()) return true;
  completedTickExpiryByThreadID.delete(thread.id);
  scheduleCompletedTickExpiry();
  return false;
}

function scheduleCompletedTickExpiry() {
  if (completedTickTimer !== undefined) clearTimeout(completedTickTimer);
  const now = Date.now();
  const expiries = [...completedTickExpiryByThreadID.values()].filter((expiry) => expiry > now);
  if (!expiries.length) {
    completedTickTimer = undefined;
    return;
  }
  completedTickTimer = window.setTimeout(() => {
    completedTickTimer = undefined;
    requestRender();
    scheduleCompletedTickExpiry();
  }, Math.min(...expiries) - now);
}

function refreshUnreadFromSidebar() {
  if (syncUnreadFromSidebar()) requestRender();
}

function unreadSyncDelay() {
  if (document.visibilityState === 'hidden') return 30000;
  return pageState.isOpen() ? 3000 : 10000;
}

function scheduleUnreadSync(delay = unreadSyncDelay()) {
  if (unreadSyncTimer !== undefined) clearTimeout(unreadSyncTimer);
  unreadSyncTimer = window.setTimeout(() => {
    unreadSyncTimer = undefined;
    refreshUnreadFromSidebar();
    scheduleUnreadSync();
  }, delay);
}

function handleVisibilityChange() {
  scheduleUnreadSync(document.visibilityState === 'hidden' ? unreadSyncDelay() : 0);
}

function isThreadUnread(thread) {
  return unreadThreadIDs.has(thread.id);
}

function deriveViewState() {
  return taskDashboardState.derive(threads, isThreadUnread, ignoredProjectPaths);
}

function openThread(thread) {
  closeDashboard();
  codexHost.navigateToThread(thread);
}

async function openCommitOrPushForProject(projectPath) {
  commitOrPushError = '';
  const thread = threads.find(
    (item) => item.runState !== 'running' && String(item.projectPath).trim() === projectPath,
  );
  if (!thread) {
    commitOrPushError = 'No idle task is available for this project.';
    renderDashboard();
    return;
  }
  if (!await codexHost.canOpenCommitOrPush()) {
    commitOrPushError = 'Commit or push is not available in this Codex version. Open a project task and use its Git controls instead.';
    renderDashboard();
    return;
  }
  closeDashboard();
  if (await codexHost.openCommitOrPush(thread)) return;
  commitOrPushError = 'The project task opened, but Codex could not start Commit or push.';
  dashboardNavigation.openTasks();
  renderDashboard();
}

function renderDashboard() {
  cancelScheduledRender();
  const state = deriveViewState();
  const rendered = taskDashboardView.render({
    threads,
    filterMode,
    visibleThreadLimit: visibleLimit,
    collapsedProjects,
    ignoredProjectPaths,
    commitOrPushError,
    isThreadUnread,
    isCompletionTickVisible,
    state,
  });
  if (rendered) viewNeedsRender = false;
}

function cancelScheduledRender() {
  if (renderFrame !== undefined) cancelAnimationFrame(renderFrame);
  if (renderFallbackTimer !== undefined) clearTimeout(renderFallbackTimer);
  renderFrame = undefined;
  renderFallbackTimer = undefined;
}

function scheduleRender() {
  if (renderFrame !== undefined) return;
  renderFrame = requestAnimationFrame(() => {
    renderFrame = undefined;
    renderDashboard();
  });
  // WebKit may heavily throttle animation frames for an occluded renderer.
  // Keep state updates timely there without affecting the normal visible-frame
  // path, which remains coalesced through requestAnimationFrame.
  renderFallbackTimer = window.setTimeout(() => {
    if (renderFrame === undefined) return;
    cancelAnimationFrame(renderFrame);
    renderFrame = undefined;
    renderFallbackTimer = undefined;
    renderDashboard();
  }, 100);
}

function requestRender() {
  if (pageState.isOpen()) {
    scheduleRender();
    return;
  }
  viewNeedsRender = true;
  taskDashboardView.updateSidebarStatus(deriveViewState());
}

function mountTaskNavigationButton() {
  if (document.getElementById(dashboardElements.elementIDs.navButton)) return true;
  const insertionPoint = codexHost.navigationInsertionPoint();
  if (!insertionPoint?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = dashboardElements.elementIDs.navButton;
  button.type = 'button';
  button.className = insertionPoint.element.className;
  button.setAttribute('aria-label', 'Task Dashboard');
  button.innerHTML = `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${dashboardIcons.render('threads')}</span>
      <span class="dashboard-nav-label">Task Dashboard</span>
    </div>
    <div class="dashboard-nav-status">
      <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="0 running tasks" title="0 running tasks" hidden><span data-navigation-running-count aria-hidden="true">0</span></span>
      <span class="dashboard-nav-changes" data-navigation-changes role="status" aria-label="0 projects with uncommitted changes" title="0 projects with uncommitted changes" hidden>${dashboardIcons.render('gitChanges')}</span>
      <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread tasks" hidden>0</strong>
    </div>`;
  if (insertionPoint.insertAfter) insertionPoint.element.after(button);
  else insertionPoint.element.parentElement.insertBefore(button, insertionPoint.element);
  taskDashboardView.updateSidebarStatus(deriveViewState());
  pageState.restoreOpenState();
  return true;
}

function mountTaskDashboardPage() {
  if (document.getElementById(dashboardElements.elementIDs.page)) return true;
  viewNeedsRender = true;
  const mounted = taskDashboardPage.mount({
    onFilter: (nextFilterMode) => {
      filterMode = nextFilterMode;
      savePreferences();
      renderDashboard();
    },
    onLoadMore: () => {
      visibleLimit += pageSize;
      renderDashboard();
    },
    onListClick: (event) => {
      const projectIgnore = event.target.closest('[data-project-ignore]');
      if (projectIgnore) {
        event.preventDefault();
        const projectPath = projectIgnore.dataset.projectIgnore;
        if (ignoredProjectPaths.has(projectPath)) ignoredProjectPaths.delete(projectPath);
        else ignoredProjectPaths.add(projectPath);
        commitOrPushError = '';
        savePreferences();
        renderDashboard();
        return;
      }
      const projectCommit = event.target.closest('[data-project-commit]');
      if (projectCommit) {
        event.preventDefault();
        void openCommitOrPushForProject(projectCommit.dataset.projectCommit);
        return;
      }
      const projectToggle = event.target.closest('[data-project-toggle]');
      if (projectToggle) {
        const projectPath = projectToggle.dataset.projectToggle;
        if (collapsedProjects.has(projectPath)) collapsedProjects.delete(projectPath);
        else collapsedProjects.add(projectPath);
        savePreferences();
        renderDashboard();
        return;
      }
      openThreadFromEvent(event);
    },
  });
  if (mounted) pageState.restoreOpenState();
  return mounted;
}

function openThreadFromEvent(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  const target = eventTarget?.closest('[data-open-thread]');
  if (!target) return;
  const thread = threads.find((item) => item.id === target.dataset.openThread);
  if (thread) openThread(thread);
}

function openDashboard() {
  if (!pageState.open()) return;
  if (viewNeedsRender) renderDashboard();
  else taskDashboardView.updateSidebarStatus(deriveViewState());
  scheduleUnreadSync(1500);
}

function closeDashboard() {
  pageState.close();
  scheduleUnreadSync();
}

function applyThreads(nextThreads) {
  threads = taskDashboardState.sortThreadsByRecency(nextThreads);
  const nextUnreadThreadIDs = new Set(
    threads.filter((thread) => thread.isUnread === true).map((thread) => thread.id),
  );
  const threadsByID = new Map(threads.map((thread) => [thread.id, thread]));
  sidebarUnreadOverrides.forEach((override, id) => {
    const thread = threadsByID.get(id);
    // Retain live observations through persistence lag, but release them when
    // acknowledged, removed, or superseded by activity in a subsequent turn.
    if (!thread || override.isUnread === (thread.isUnread === true)
      || override.revision !== unreadRevision(thread)) {
      sidebarUnreadOverrides.delete(id);
      return;
    }
    if (override.isUnread) nextUnreadThreadIDs.add(id);
    else nextUnreadThreadIDs.delete(id);
  });
  const currentThreadIDs = new Set(threads.map((thread) => thread.id));
  completedTickExpiryByThreadID.forEach((_, threadID) => {
    if (!currentThreadIDs.has(threadID)) completedTickExpiryByThreadID.delete(threadID);
  });
  syncUnreadFromSidebar(nextUnreadThreadIDs);
  scheduleUnreadSync(1500);
  // A native refresh can update the catalog, unread state, and Git state in a
  // short burst. Keep the renderer responsive by applying only the latest
  // snapshot in the next frame instead of rebuilding the task list for each
  // delivery.
  if (pageState.isOpen()) {
    viewNeedsRender = true;
    scheduleRender();
  } else {
    requestRender();
  }
  return true;
}

function startMonitoring() {
  if (!unreadMonitoringStarted) {
    unreadMonitoringStarted = true;
    scheduleUnreadSync();
    document.addEventListener('visibilitychange', handleVisibilityChange);
  }
}

function destroy() {
  pageState.close();
  cancelScheduledRender();
  if (unreadSyncTimer !== undefined) clearTimeout(unreadSyncTimer);
  if (completedTickTimer !== undefined) clearTimeout(completedTickTimer);
  unreadSyncTimer = undefined;
  completedTickTimer = undefined;
  completedTickExpiryByThreadID.clear();
  sidebarUnreadOverrides.clear();
  unreadMonitoringStarted = false;
  viewNeedsRender = true;
  document.removeEventListener('visibilitychange', handleVisibilityChange);
}

return {
  mountNavigation: mountTaskNavigationButton,
  mountPage: mountTaskDashboardPage,
  restoreOpenState: pageState.restoreOpenState,
  startMonitoring,
  requestRender,
  syncUnread: syncUnreadFromSidebar,
  destroy,
  open: openDashboard,
  close: closeDashboard,
  isOpen: pageState.isOpen,
  applyThreads,
  findThread: (id) => threads.find((thread) => thread.id === id),
};
})();
