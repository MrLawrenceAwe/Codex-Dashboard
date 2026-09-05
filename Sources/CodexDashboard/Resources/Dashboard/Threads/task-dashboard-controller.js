const taskDashboard = (() => {
// Snapshots are sorted newest-first on arrival; lookups preserve that order.
let threads = [];
const storedPreferences = taskDashboardState.loadPreferences();
let filterMode = storedPreferences.filterMode;
const pageSize = 60;
let visibleLimit = pageSize;
const { collapsedProjects, mutedProjectPaths } = storedPreferences;
let renderFrame;
let renderFallbackTimer;
const pageState = createPageVisibilityController({
  pageID: dashboardElements.elementIDs.page,
  navigationID: dashboardElements.elementIDs.navButton,
  rootClass: 'codex-dashboard-open',
});
let viewNeedsRender = true;
let commitOrPushError = '';
const unreadState = createThreadUnreadState({ isOpen: pageState.isOpen, onChange: requestRender });
const { isThreadUnread, isCompletionTickVisible } = unreadState;

function savePreferences() {
  taskDashboardState.savePreferences({
    filterMode,
    collapsedProjects,
    mutedProjectPaths,
  });
}

function deriveViewState() {
  return taskDashboardState.derive(threads, isThreadUnread, mutedProjectPaths);
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
  if (document.getElementById(dashboardElements.elementIDs.navButton)) return true;
  if (!mountDashboardNavigationButton({
    id: dashboardElements.elementIDs.navButton,
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
  const thread = unreadState.findThread(target.dataset.openThread);
  if (thread) openThread(thread);
}

function openDashboard() {
  if (!pageState.open()) return;
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
  viewNeedsRender = true;
}

return {
  mountNavigation: mountTaskNavigationButton,
  mountPage: mountTaskDashboardPage,
  restoreOpenState: pageState.restoreOpenState,
  startMonitoring: unreadState.startMonitoring,
  requestRender,
  syncUnread: unreadState.syncUnread,
  destroy,
  open: openDashboard,
  close: closeDashboard,
  isOpen: pageState.isOpen,
  applyThreads,
  findThread: unreadState.findThread,
};
})();
