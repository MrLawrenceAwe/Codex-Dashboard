const threadDashboard = (() => {
const navigationEventTypes = ['pointerdown', 'mousedown', 'click', 'keydown'];
const routeEventTypes = ['message', 'popstate', 'hashchange'];

let threads = [];
let accounts = [];
let activeAccountID = null;
let accountStatusMessage = null;
let pendingAccountAction = null;
const storedPreferences = threadDashboardState.loadPreferences();
let filterMode = storedPreferences.filterMode;
let searchTerm = '';
const threadPageSize = 60;
let visibleThreadLimit = threadPageSize;
const { collapsedProjects, ignoredProjectPaths } = storedPreferences;
let structureObserver;
let sidebarMutationObserver;
let composerMutationObserver;
let resizeObserver;
let observedSidebar;
let observedStructureRoot;
let observedMutationSidebar;
let observedComposerRoot;
let mutationFrame;
let unreadSyncTimer;
let renderFrame;
let pendingUnreadStateSync = false;
let pendingHostReconciliation = false;
let dashboardIsOpen = false;
let dashboardNeedsRender = true;
let unreadThreadIDs = new Set();
let commitOrPushError = '';

function saveDashboardPreferences() {
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
  if (syncUnreadFromSidebar()) requestDashboardRender();
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

function handleHostNavigation(event) {
  if (event.type === 'message') {
    if (event.data?.type === 'navigate-to-route') {
      if (dashboardIsOpen) closeDashboard();
      scheduleHostReconciliation({ rebindHosts: true });
    }
    return;
  }
  if (event.type === 'popstate' || event.type === 'hashchange') {
    if (dashboardIsOpen) closeDashboard();
    scheduleHostReconciliation({ rebindHosts: true });
    return;
  }
  if (event.type === 'keydown') {
    const opensNewChat = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'n';
    if (dashboardIsOpen && opensNewChat) closeDashboard();
    return;
  }
  const eventTarget = event.target instanceof Element ? event.target : null;
  if (eventTarget?.closest(`#${dashboardElements.elementIDs.navButton}`)) {
    event.preventDefault();
    event.stopPropagation();
    if (event.type === 'click') openDashboard();
    return;
  }
  if (event.type !== 'click') return;
  if (eventTarget?.closest('aside') && !eventTarget.closest(`#${dashboardElements.elementIDs.navButton}`)) {
    if (dashboardIsOpen) closeDashboard();
    scheduleHostReconciliation({ rebindHosts: true });
  }
}

function deriveDashboardState() {
  return threadDashboardState.derive(threads, isThreadUnread, ignoredProjectPaths);
}

function openThread(thread) {
  closeDashboard();
  codexHost.navigateToThread(thread);
}

async function openProjectCommitOrPush(projectPath) {
  commitOrPushError = '';
  const candidates = threads
    .filter((item) => item.runState !== 'running' && String(item.projectPath).trim() === projectPath)
    .sort((left, right) => Number(right.recencyTimestampMilliseconds || 0) - Number(left.recencyTimestampMilliseconds || 0));
  const [thread] = candidates;
  if (!thread) {
    commitOrPushError = 'No idle thread is available for this project.';
    renderDashboard();
    return;
  }
  if (!await codexHost.canOpenCommitOrPush()) {
    commitOrPushError = 'Commit or push is not available in this Codex version. Open a project thread and use its Git controls instead.';
    renderDashboard();
    return;
  }
  closeDashboard();
  if (await codexHost.openCommitOrPush(thread)) return;
  commitOrPushError = 'The project thread opened, but Codex could not start Commit or push.';
  openDashboard();
}

function renderDashboard() {
  const state = deriveDashboardState();
  const rendered = threadDashboardView.render({
    threads,
    filterMode,
    searchTerm,
    visibleThreadLimit,
    collapsedProjects,
    ignoredProjectPaths,
    commitOrPushError,
    isThreadUnread,
    state,
  });
  if (rendered) dashboardNeedsRender = false;
}

function renderAccountControls() {
  const select = document.querySelector('[data-account-select]');
  if (!select) return;
  const options = accounts.map((account) => `
    <option value="${dashboardElements.escapeHTML(account.id)}"${account.id === activeAccountID ? ' selected' : ''}>
      ${dashboardElements.escapeHTML(account.name)}
    </option>`).join('');
  select.innerHTML = options || '<option value="">Current account</option>';
  const notice = document.querySelector('[data-dashboard-notice]');
  if (notice && accountStatusMessage) {
    notice.textContent = accountStatusMessage;
    notice.hidden = false;
  }
}

function queueAccountAction(action) {
  pendingAccountAction = action;
  accountStatusMessage = action.type === 'switch'
    ? 'Switching accounts…'
    : (action.type === 'add' ? 'Preparing account sign-in…' : 'Saving account…');
  renderAccountControls();
}

function consumeAccountAction() {
  if (!pendingAccountAction) return null;
  const action = pendingAccountAction;
  pendingAccountAction = null;
  return JSON.stringify(action);
}

function scheduleDashboardRender() {
  if (renderFrame !== undefined) return;
  renderFrame = requestAnimationFrame(() => {
    renderFrame = undefined;
    renderDashboard();
  });
}

function requestDashboardRender() {
  if (dashboardIsOpen) {
    scheduleDashboardRender();
    return;
  }
  dashboardNeedsRender = true;
  threadDashboardView.updateSidebarStatus(deriveDashboardState());
}

function syncContentInset() {
  const sidebar = codexHost.sidebar();
  const pageHost = codexHost.pageHost();
  const sidebarRect = sidebar?.getBoundingClientRect();
  const hostRect = pageHost?.getBoundingClientRect();
  const hostScale = pageHost?.offsetWidth > 0 ? hostRect.width / pageHost.offsetWidth : 1;
  const width = sidebarRect && hostRect && Number.isFinite(hostScale) && hostScale > 0
    ? Math.max(0, (sidebarRect.right - hostRect.left) / hostScale)
    : 0;
  document.documentElement.style.setProperty('--codex-dashboard-content-left', `${Math.round(width)}px`);
}

function observeSidebar() {
  const sidebar = codexHost.sidebar();
  if (!resizeObserver || sidebar === observedSidebar) return;
  resizeObserver.disconnect();
  if (sidebar) resizeObserver.observe(sidebar);
  observedSidebar = sidebar;
}

function attachPageToCodexContent() {
  const page = document.getElementById(dashboardElements.elementIDs.page);
  const pageHost = codexHost.pageHost();
  if (page && pageHost && page.parentElement !== pageHost) pageHost.append(page);
}

function composerMutationRoot() {
  const composer = codexUIContracts.composer();
  return composer?.closest('form') || composer?.parentElement || null;
}

function observeMutationHosts() {
  const structureRoot = codexHost.pageHost();
  if (structureObserver && structureRoot !== observedStructureRoot) {
    structureObserver.disconnect();
    if (structureRoot) structureObserver.observe(structureRoot, { childList: true, subtree: true });
    observedStructureRoot = structureRoot;
  }
  const sidebar = codexHost.sidebar();
  if (sidebarMutationObserver && sidebar !== observedMutationSidebar) {
    sidebarMutationObserver.disconnect();
    if (sidebar) sidebarMutationObserver.observe(sidebar, { childList: true, subtree: true });
    observedMutationSidebar = sidebar;
  }
  const composerRoot = composerMutationRoot();
  if (composerMutationObserver && composerRoot !== observedComposerRoot) {
    composerMutationObserver.disconnect();
    if (composerRoot) composerMutationObserver.observe(composerRoot, { childList: true, subtree: true });
    observedComposerRoot = composerRoot;
  }
}

function scheduleHostReconciliation({ syncUnread = false, rebindHosts = false } = {}) {
  pendingUnreadStateSync ||= syncUnread;
  pendingHostReconciliation ||= rebindHosts;
  if (mutationFrame !== undefined) return;
  mutationFrame = requestAnimationFrame(() => {
    mutationFrame = undefined;
    const shouldSyncUnread = pendingUnreadStateSync;
    const shouldRebindHosts = pendingHostReconciliation;
    pendingUnreadStateSync = false;
    pendingHostReconciliation = false;
    const restoredPage = !document.getElementById(dashboardElements.elementIDs.page);
    if (restoredPage) mountDashboardPage();
    if (!document.getElementById(dashboardElements.elementIDs.navButton)) mountNavigationButton();
    if (dashboardIsOpen && restoredPage) openDashboard();
    attachPageToCodexContent();
    observeSidebar();
    if (shouldRebindHosts) {
      observeMutationHosts();
      promptLauncher.scheduleSync();
    }
    if (shouldSyncUnread && syncUnreadFromSidebar()) requestDashboardRender();
  });
}

function handleStructureMutations() {
  const launcher = document.querySelector('[data-codex-prompt-launcher]');
  if (
    document.getElementById(dashboardElements.elementIDs.page)
      && document.getElementById(dashboardElements.elementIDs.navButton)
      && launcher?.isConnected
      && observedComposerRoot?.isConnected
  ) return;
  scheduleHostReconciliation({ rebindHosts: true });
}

function handleSidebarMutations() {
  scheduleHostReconciliation({ syncUnread: true });
}

function handleComposerMutations() {
  if (composerMutationRoot() !== observedComposerRoot) {
    scheduleHostReconciliation({ rebindHosts: true });
    return;
  }
  promptLauncher.scheduleSync();
}

function mountNavigationButton() {
  const insertionPoint = codexHost.navigationInsertionPoint();
  if (!insertionPoint?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = dashboardElements.elementIDs.navButton;
  button.type = 'button';
  button.className = insertionPoint.element.className;
  button.setAttribute('aria-label', 'Thread Dashboard');
  button.innerHTML = `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${threadMarkup.icon('threads')}</span>
      <span class="dashboard-nav-label">Thread Dashboard</span>
    </div>
    <div class="dashboard-nav-status">
      <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="0 running threads" title="0 running threads" hidden><span data-navigation-running-count aria-hidden="true">0</span></span>
      <span class="dashboard-nav-changes" data-navigation-changes role="status" aria-label="0 projects with uncommitted changes" title="0 projects with uncommitted changes" hidden>${threadMarkup.icon('gitChanges')}</span>
      <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread threads" hidden>0</strong>
    </div>`;
  if (insertionPoint.insertAfter) insertionPoint.element.after(button);
  else insertionPoint.element.parentElement.insertBefore(button, insertionPoint.element);
  threadDashboardView.updateSidebarStatus(deriveDashboardState());
  return true;
}

function mountDashboardPage() {
  dashboardNeedsRender = true;
  return threadDashboardPage.mount({
    onFilter: (nextFilterMode) => {
      filterMode = nextFilterMode;
      saveDashboardPreferences();
      renderDashboard();
    },
    onSearch: (nextSearchTerm) => {
      searchTerm = nextSearchTerm;
      visibleThreadLimit = threadPageSize;
      scheduleDashboardRender();
    },
    onLoadMore: () => {
      visibleThreadLimit += threadPageSize;
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
      saveDashboardPreferences();
      renderDashboard();
      return;
    }
    const projectCommit = event.target.closest('[data-project-commit]');
    if (projectCommit) {
      event.preventDefault();
      void openProjectCommitOrPush(projectCommit.dataset.projectCommit);
      return;
    }
    const projectToggle = event.target.closest('[data-project-toggle]');
    if (projectToggle) {
      const projectPath = projectToggle.dataset.projectToggle;
      if (collapsedProjects.has(projectPath)) collapsedProjects.delete(projectPath);
      else collapsedProjects.add(projectPath);
      saveDashboardPreferences();
      renderDashboard();
      return;
    }
    openThreadFromEvent(event);
    },
    onAccountAction: queueAccountAction,
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
  if (dashboardNeedsRender) renderDashboard();
  else threadDashboardView.updateSidebarStatus(deriveDashboardState());
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

function applySnapshot(nextSnapshot) {
  const snapshot = threadDashboardState.normalizeSnapshot(nextSnapshot);
  threads = snapshot.threads;
  accounts = snapshot.accounts;
  activeAccountID = snapshot.activeAccountID;
  accountStatusMessage = snapshot.accountStatusMessage;
  unreadThreadIDs = new Set(
    threads.filter((thread) => thread.isUnread === true).map((thread) => thread.id),
  );
  syncUnreadFromSidebar();
  scheduleUnreadSync(1500);
  requestDashboardRender();
  renderAccountControls();
}

function activeProject() {
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
  if (!document.body) return false;
  if (!document.getElementById(dashboardElements.elementIDs.style)) {
    const style = document.createElement('style');
    style.id = dashboardElements.elementIDs.style;
    style.textContent = DASHBOARD_CSS;
    document.head.append(style);
  }
  const pageWasMissing = !document.getElementById(dashboardElements.elementIDs.page);
  if (pageWasMissing) mountDashboardPage();
  if (!document.getElementById(dashboardElements.elementIDs.navButton)) mountNavigationButton();
  attachPageToCodexContent();
  syncContentInset();
  promptLibrary.mount();
  if (dashboardIsOpen && pageWasMissing) openDashboard();

  if (!structureObserver) {
    structureObserver = new MutationObserver(handleStructureMutations);
    sidebarMutationObserver = new MutationObserver(handleSidebarMutations);
    composerMutationObserver = new MutationObserver(handleComposerMutations);
    observeMutationHosts();
  }
  if (unreadSyncTimer === undefined) {
    scheduleUnreadSync();
  }
  if (!resizeObserver && typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(syncContentInset);
    observeSidebar();
  }
  navigationEventTypes.forEach((type) => {
    document.addEventListener(type, handleHostNavigation, true);
  });
  routeEventTypes.forEach((type) => {
    window.addEventListener(type, handleHostNavigation, true);
  });
  document.addEventListener('visibilitychange', handleVisibilityChange);
  return Boolean(
    document.getElementById(dashboardElements.elementIDs.style)
      && document.getElementById(dashboardElements.elementIDs.page)
      && document.getElementById(dashboardElements.elementIDs.navButton)
  );
}

function destroy() {
  dashboardIsOpen = false;
  structureObserver?.disconnect();
  sidebarMutationObserver?.disconnect();
  composerMutationObserver?.disconnect();
  resizeObserver?.disconnect();
  if (mutationFrame !== undefined) cancelAnimationFrame(mutationFrame);
  if (renderFrame !== undefined) cancelAnimationFrame(renderFrame);
  if (unreadSyncTimer !== undefined) clearTimeout(unreadSyncTimer);
  structureObserver = undefined;
  sidebarMutationObserver = undefined;
  composerMutationObserver = undefined;
  resizeObserver = undefined;
  mutationFrame = undefined;
  renderFrame = undefined;
  unreadSyncTimer = undefined;
  pendingUnreadStateSync = false;
  pendingHostReconciliation = false;
  dashboardNeedsRender = true;
  observedSidebar = undefined;
  observedStructureRoot = undefined;
  observedMutationSidebar = undefined;
  observedComposerRoot = undefined;
  promptLibrary.unmount();
  navigationEventTypes.forEach((type) => {
    document.removeEventListener(type, handleHostNavigation, true);
  });
  routeEventTypes.forEach((type) => {
    window.removeEventListener(type, handleHostNavigation, true);
  });
  document.removeEventListener('visibilitychange', handleVisibilityChange);
  document.documentElement.classList.remove('codex-dashboard-open');
  document.documentElement.style.removeProperty('--codex-dashboard-content-left');
  Object.values(dashboardElements.elementIDs).forEach((id) => document.getElementById(id)?.remove());
  delete window.__codexDashboard;
}

return {
  ensureMounted,
  destroy,
  open: openDashboard,
  isOpen,
  applySnapshot,
  consumeAccountAction,
  activeProject,
};
})();
