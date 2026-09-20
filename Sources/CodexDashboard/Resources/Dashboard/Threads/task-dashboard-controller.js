const taskDashboard = (() => {
// Snapshots are sorted newest-first on arrival; lookups preserve that order.
let threads = [];
const storedPreferences = taskDashboardState.loadPreferences();
let filterMode = storedPreferences.filterMode;
const pageSize = 10;
let visibleLimit = pageSize;
const { collapsedProjectPaths, mutedProjectPaths } = storedPreferences;
let renderFrame;
let renderFallbackTimer;
const pageState = createPageVisibilityController({
  pageID: dashboardElements.elementIDs.taskPage,
  navigationID: dashboardElements.elementIDs.taskNavButton,
  rootClass: 'codex-dashboard-open',
});
let viewNeedsRender = true;
let commitOrPushError = '';
let interruptedThreadIDs = new Set();
const unreadState = createThreadUnreadState({ isOpen: pageState.isOpen, onChange: requestRender });
const { isThreadUnread, isCompletionTickVisible } = unreadState;

function savePreferences() {
  taskDashboardState.savePreferences({
    filterMode,
    collapsedProjectPaths,
    mutedProjectPaths,
  });
}

function deriveViewState() {
  return taskDashboardState.summarizeActivity(threads, isThreadUnread, mutedProjectPaths);
}

function syncSidebarMarkers() {
  const nextInterruptedThreadIDs = new Set(
    threads
      .filter((thread) => thread.latestLifecycleEventKind === 'forcedHalt')
      .map((thread) => thread.id),
  );
  interruptedThreadIDs.forEach((threadID) => {
    if (nextInterruptedThreadIDs.has(threadID)) return;
    document.querySelectorAll('[data-codex-sidebar-interrupted]').forEach((marker) => {
      if (marker.dataset.codexSidebarInterrupted === threadID) marker.remove();
    });
  });
  interruptedThreadIDs = nextInterruptedThreadIDs;
  interruptedThreadIDs.forEach((threadID) => {
    const row = codexUIContracts.threadRow(threadID);
    if (!row) return;
    let marker = row.querySelector('[data-codex-sidebar-interrupted]');
    if (!marker) {
      const title = row.querySelector('[data-thread-title-trigger]');
      const markerHost = title?.parentElement;
      if (!markerHost) return;
      marker = document.createElement('span');
      marker.setAttribute('data-codex-sidebar-interrupted', threadID);
      marker.textContent = 'Interrupted';
      markerHost.insertBefore(marker, title);
    }
    marker.setAttribute('role', 'status');
    marker.setAttribute('aria-label', 'Interrupted because the usage limit was reached');
    marker.setAttribute('title', 'This task was interrupted because the usage limit was reached');
  });
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
    collapsedProjectPaths,
    mutedProjectPaths,
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
  if (document.getElementById(dashboardElements.elementIDs.taskNavButton)) return true;
  if (!mountDashboardNavigationButton({
    id: dashboardElements.elementIDs.taskNavButton,
    label: 'Task Dashboard',
    markup: `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${dashboardIcons.render('threads')}</span>
      <span class="dashboard-nav-label">Task Dashboard</span>
    </div>
    <div class="dashboard-nav-status">
      <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="0 running tasks" title="0 running tasks" hidden><span data-navigation-running-count aria-hidden="true">0</span></span>
      <span class="dashboard-nav-changes" data-navigation-changes role="status" aria-label="0 projects with uncommitted changes" title="0 projects with uncommitted changes" hidden>${dashboardIcons.render('gitChanges')}</span>
      <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread tasks" hidden>0</strong>
    </div>`,
  })) return false;
  taskDashboardView.updateSidebarStatus(deriveViewState());
  pageState.applyVisibility();
  return true;
}

function mountTaskDashboardPage() {
  if (document.getElementById(dashboardElements.elementIDs.taskPage)) return true;
  viewNeedsRender = true;
  const mounted = taskDashboardPage.mount({
    onFilter: (nextFilterMode) => {
      if (filterMode === nextFilterMode) return;
      filterMode = nextFilterMode;
      visibleLimit = pageSize;
      savePreferences();
      renderDashboard();
    },
    onLoadMore: () => {
      visibleLimit += pageSize;
      renderDashboard();
    },
    onListClick: (event) => {
      const projectMute = event.target.closest('[data-project-mute]');
      if (projectMute) {
        event.preventDefault();
        const projectPath = projectMute.dataset.projectMute;
        if (mutedProjectPaths.has(projectPath)) mutedProjectPaths.delete(projectPath);
        else mutedProjectPaths.add(projectPath);
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
        if (collapsedProjectPaths.has(projectPath)) collapsedProjectPaths.delete(projectPath);
        else collapsedProjectPaths.add(projectPath);
        savePreferences();
        renderDashboard();
        return;
      }
      openThreadFromEvent(event);
    },
  });
  if (mounted) pageState.applyVisibility();
  return mounted;
}

function openThreadFromEvent(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  const target = eventTarget?.closest('[data-open-thread]');
  if (!target) return;
  const thread = unreadState.findThread(target.dataset.openThread);
  if (thread) openThread(thread);
}

function openDashboard() {
  if (!pageState.open()) return;
  if (unreadState.syncUnread()) viewNeedsRender = true;
  if (viewNeedsRender) renderDashboard();
  else taskDashboardView.updateSidebarStatus(deriveViewState());
  unreadState.scheduleUnreadSync(1500);
}

function closeDashboard() {
  pageState.close();
  unreadState.scheduleUnreadSync();
}

function applyThreads(nextThreads) {
  threads = taskDashboardState.sortThreadsByRecency(nextThreads);
  todoList.refreshChatOptions();
  syncSidebarMarkers();
  unreadState.applyThreads(threads);
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

function destroy() {
  pageState.close();
  cancelScheduledRender();
  unreadState.destroy();
  document.querySelectorAll('[data-codex-sidebar-interrupted]').forEach((marker) => marker.remove());
  interruptedThreadIDs.clear();
  viewNeedsRender = true;
}

function chatsForProject(project) {
  const projectName = String(project?.name || '').trim().toLocaleLowerCase();
  if (!projectName) return [];
  return threads.filter((thread) => (
    String(thread.projectName || '').trim().toLocaleLowerCase() === projectName
  )).map((thread) => ({ id: thread.id, title: thread.title }));
}

return {
  mountNavigation: mountTaskNavigationButton,
  mountPage: mountTaskDashboardPage,
  applyVisibility: pageState.applyVisibility,
  startMonitoring: unreadState.startMonitoring,
  requestRender,
  syncSidebarMarkers,
  syncUnread: unreadState.syncUnread,
  destroy,
  open: openDashboard,
  close: closeDashboard,
  isOpen: pageState.isOpen,
  applyThreads,
  chatsForProject,
  findThread: unreadState.findThread,
};
})();
