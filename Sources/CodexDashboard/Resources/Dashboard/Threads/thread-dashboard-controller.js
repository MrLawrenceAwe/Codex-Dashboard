const threadDashboard = (() => {
let threads = [];
const storedPreferences = threadDashboardState.loadPreferences();
let filterMode = storedPreferences.filterMode;
let searchTerm = '';
const threadPageSize = 60;
let visibleThreadLimit = threadPageSize;
const { collapsedProjects, ignoredProjectPaths } = storedPreferences;
let unreadSyncTimer;
let renderFrame;
let unreadMonitoringStarted = false;
let dashboardIsOpen = false;
let threadViewNeedsRender = true;
let unreadThreadIDs = new Set();
let gitFlowError = '';

function savePreferences() {
  threadDashboardState.savePreferences({
    filterMode,
    collapsedProjects,
    ignoredProjectPaths,
  });
}

function syncUnreadFromSidebar() {
  const readStates = codexHost.threadReadStates();
  let changed = false;
  readStates.forEach((isUnread, id) => {
    if (isUnread === unreadThreadIDs.has(id)) return;
    changed = true;
    if (isUnread) unreadThreadIDs.add(id);
    else unreadThreadIDs.delete(id);
  });
  return changed;
}

function refreshUnreadFromSidebar() {
  if (syncUnreadFromSidebar()) requestThreadRender();
}

function unreadSyncDelay() {
  if (document.visibilityState === 'hidden') return 30000;
  return dashboardIsOpen ? 3000 : 10000;
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

function deriveThreadViewState() {
  return threadDashboardState.derive(threads, isThreadUnread, ignoredProjectPaths);
}

function openThread(thread) {
  closeDashboard();
  codexHost.navigateToThread(thread);
}

async function openProjectGitFlow(projectPath) {
  gitFlowError = '';
  const candidates = threads
    .filter((item) => item.runState !== 'running' && String(item.projectPath).trim() === projectPath)
    .sort((left, right) => Number(right.recencyEpochMillis || 0) - Number(left.recencyEpochMillis || 0));
  const [thread] = candidates;
  if (!thread) {
    gitFlowError = 'No idle thread is available for this project.';
    renderThreadView();
    return;
  }
  if (!await codexHost.canOpenCommitOrPush()) {
    gitFlowError = 'Commit or push is not available in this Codex version. Open a project thread and use its Git controls instead.';
    renderThreadView();
    return;
  }
  closeDashboard();
  if (await codexHost.openCommitOrPush(thread)) return;
  gitFlowError = 'The project thread opened, but Codex could not start Commit or push.';
  openDashboard();
  renderThreadView();
}

function renderThreadView() {
  const state = deriveThreadViewState();
  const rendered = threadDashboardView.render({
    threads,
    filterMode,
    searchTerm,
    visibleThreadLimit,
    collapsedProjects,
    ignoredProjectPaths,
    commitOrPushError: gitFlowError,
    isThreadUnread,
    state,
  });
  if (rendered) threadViewNeedsRender = false;
}

function scheduleThreadRender() {
  if (renderFrame !== undefined) return;
  renderFrame = requestAnimationFrame(() => {
    renderFrame = undefined;
    renderThreadView();
  });
}

function requestThreadRender() {
  if (dashboardIsOpen) {
    scheduleThreadRender();
    return;
  }
  threadViewNeedsRender = true;
  threadDashboardView.updateSidebarStatus(deriveThreadViewState());
}

function mountNavigationButton() {
  const insertionPoint = codexHost.navigationInsertionPoint();
  if (!insertionPoint?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = dashboardElements.elementIDs.navButton;
  button.type = 'button';
  button.className = insertionPoint.element.className;
  button.setAttribute('aria-label', 'Task Dashboard');
  button.innerHTML = `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${threadMarkup.icon('threads')}</span>
      <span class="dashboard-nav-label">Task Dashboard</span>
    </div>
    <div class="dashboard-nav-status">
      <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="0 running threads" title="0 running threads" hidden><span data-navigation-running-count aria-hidden="true">0</span></span>
      <span class="dashboard-nav-changes" data-navigation-changes role="status" aria-label="0 projects with uncommitted changes" title="0 projects with uncommitted changes" hidden>${threadMarkup.icon('gitChanges')}</span>
      <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread threads" hidden>0</strong>
    </div>`;
  if (insertionPoint.insertAfter) insertionPoint.element.after(button);
  else insertionPoint.element.parentElement.insertBefore(button, insertionPoint.element);
  threadDashboardView.updateSidebarStatus(deriveThreadViewState());
  return true;
}

function mountDashboardPage() {
  threadViewNeedsRender = true;
  return threadDashboardPage.mount({
    onFilter: (nextFilterMode) => {
      filterMode = nextFilterMode;
      savePreferences();
      renderThreadView();
    },
    onSearch: (nextSearchTerm) => {
      searchTerm = nextSearchTerm;
      visibleThreadLimit = threadPageSize;
      scheduleThreadRender();
    },
    onLoadMore: () => {
      visibleThreadLimit += threadPageSize;
      renderThreadView();
    },
    onListClick: (event) => {
    const projectIgnore = event.target.closest('[data-project-ignore]');
    if (projectIgnore) {
      event.preventDefault();
      const projectPath = projectIgnore.dataset.projectIgnore;
      if (ignoredProjectPaths.has(projectPath)) ignoredProjectPaths.delete(projectPath);
      else ignoredProjectPaths.add(projectPath);
      gitFlowError = '';
      savePreferences();
      renderThreadView();
      return;
    }
    const projectCommit = event.target.closest('[data-project-commit]');
    if (projectCommit) {
      event.preventDefault();
      void openProjectGitFlow(projectCommit.dataset.projectCommit);
      return;
    }
    const projectToggle = event.target.closest('[data-project-toggle]');
    if (projectToggle) {
      const projectPath = projectToggle.dataset.projectToggle;
      if (collapsedProjects.has(projectPath)) collapsedProjects.delete(projectPath);
      else collapsedProjects.add(projectPath);
      savePreferences();
      renderThreadView();
      return;
    }
    openThreadFromEvent(event);
    },
  });
}

function openThreadFromEvent(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  const target = eventTarget?.closest('[data-open-thread]');
  if (!target) return;
  const thread = threads.find((item) => item.id === target.dataset.openThread);
  if (thread) openThread(thread);
}

function openDashboard() {
  const page = document.getElementById(dashboardElements.elementIDs.page);
  if (!page) return;
  dashboardIsOpen = true;
  page.classList.add('is-open');
  document.documentElement.classList.add('codex-dashboard-open');
  document.getElementById(dashboardElements.elementIDs.navButton)?.setAttribute('aria-current', 'page');
  if (threadViewNeedsRender) renderThreadView();
  else threadDashboardView.updateSidebarStatus(deriveThreadViewState());
  scheduleUnreadSync(1500);
}

function closeDashboard() {
  dashboardIsOpen = false;
  document.getElementById(dashboardElements.elementIDs.page)?.classList.remove('is-open');
  document.documentElement.classList.remove('codex-dashboard-open');
  document.getElementById(dashboardElements.elementIDs.navButton)?.removeAttribute('aria-current');
  scheduleUnreadSync();
}

function isOpen() {
  return dashboardIsOpen;
}

function applyThreads(nextThreads) {
  threads = threadDashboardState.normalizeThreads(nextThreads);
  unreadThreadIDs = new Set(
    threads.filter((thread) => thread.isUnread === true).map((thread) => thread.id),
  );
  syncUnreadFromSidebar();
  scheduleUnreadSync(1500);
  requestThreadRender();
}

function scopeProject() {
  const selectedProject = codexUIContracts.activeComposerProject();
  if (selectedProject) return selectedProject;
  const activeThreadID = codexUIContracts.activeComposerThreadID();
  const thread = threads.find((item) => item.id === activeThreadID);
  const projectPath = String(thread?.projectPath || '').trim();
  if (!projectPath) return null;
  return {
    name: String(thread?.projectName || '').trim() || projectPath.split('/').filter(Boolean).at(-1) || projectPath,
    path: projectPath,
  };
}

function ensureMounted() {
  const mounted = dashboardLifecycle.ensureMounted({
    close: closeDashboard,
    isOpen,
    mountNavigation: mountNavigationButton,
    mountPage: mountDashboardPage,
    open: openDashboard,
    requestRender: requestThreadRender,
    syncUnread: syncUnreadFromSidebar,
  });
  if (!unreadMonitoringStarted) {
    unreadMonitoringStarted = true;
    scheduleUnreadSync();
    document.addEventListener('visibilitychange', handleVisibilityChange);
  }
  return mounted;
}

function destroy() {
  dashboardIsOpen = false;
  if (renderFrame !== undefined) cancelAnimationFrame(renderFrame);
  if (unreadSyncTimer !== undefined) clearTimeout(unreadSyncTimer);
  renderFrame = undefined;
  unreadSyncTimer = undefined;
  unreadMonitoringStarted = false;
  threadViewNeedsRender = true;
  document.removeEventListener('visibilitychange', handleVisibilityChange);
  dashboardLifecycle.destroy();
  delete window.__codexDashboard;
}

return {
  ensureMounted,
  destroy,
  open: openDashboard,
  isOpen,
  applyThreads,
  scopeProject,
};
})();
