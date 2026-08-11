const threadDashboard = (() => {
const navigationEventTypes = ['pointerdown', 'mousedown', 'click', 'keydown'];
const routeEventTypes = ['message', 'popstate', 'hashchange'];

let threads = [];
const storedPreferences = threadDashboardState.loadPreferences();
let filterMode = storedPreferences.filterMode;
let searchTerm = '';
const threadPageSize = 60;
let visibleThreadLimit = threadPageSize;
let viewMode = storedPreferences.viewMode;
const { collapsedProjects } = storedPreferences;
let mutationObserver;
let resizeObserver;
let observedSidebar;
let mutationFrame;
let unreadSyncTimer;
let renderFrame;
let pendingSidebarMutation = false;
let dashboardIsOpen = false;
let dashboardNeedsRender = true;
let unreadThreadIDs = new Set();
let handoffError = '';

function saveDashboardPreferences() {
  threadDashboardState.savePreferences({ filterMode, viewMode, collapsedProjects });
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
    if (dashboardIsOpen && event.data?.type === 'navigate-to-route') closePage();
    return;
  }
  if (event.type === 'popstate' || event.type === 'hashchange') {
    if (dashboardIsOpen) closePage();
    return;
  }
  if (event.type === 'keydown') {
    const opensNewChat = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'n';
    if (dashboardIsOpen && opensNewChat) closePage();
    return;
  }
  const eventTarget = event.target instanceof Element ? event.target : null;
  if (eventTarget?.closest(`#${dashboardDOM.elementIDs.navButton}`)) {
    event.preventDefault();
    event.stopPropagation();
    if (event.type === 'click') openPage();
    return;
  }
  if (event.type !== 'click' || !dashboardIsOpen) return;
  if (eventTarget?.closest('aside') && !eventTarget.closest(`#${dashboardDOM.elementIDs.navButton}`)) closePage();
}

function deriveDashboardState() {
  return threadDashboardState.derive(threads, isThreadUnread);
}

function openThread(thread) {
  closePage();
  codexHost.navigateToThread(thread);
}

async function openProjectCommitOrPush(projectPath) {
  handoffError = '';
  const candidates = threads
    .filter((item) => item.runState !== 'running' && String(item.projectPath).trim() === projectPath)
    .sort((left, right) => Number(right.recencyTimestamp || 0) - Number(left.recencyTimestamp || 0));
  const [thread] = candidates;
  if (!thread) {
    handoffError = 'No idle thread is available for this project.';
    renderDashboard();
    return;
  }
  closePage();
  if (await codexHost.openCommitOrPush(thread)) return;
  handoffError = 'Codex’s Commit or push control could not be opened. The renderer contract may have changed.';
  openPage();
}

function renderDashboard() {
  const state = deriveDashboardState();
  const rendered = threadDashboardView.render({
    threads,
    filterMode,
    searchTerm,
    visibleThreadLimit,
    viewMode,
    collapsedProjects,
    handoffError,
    isThreadUnread,
    state,
  });
  if (rendered) dashboardNeedsRender = false;
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
  const width = sidebar ? Math.max(0, sidebar.getBoundingClientRect().right) : 0;
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
  const page = document.getElementById(dashboardDOM.elementIDs.page);
  const pageHost = codexHost.pageHost();
  if (page && pageHost && page.parentElement !== pageHost) pageHost.append(page);
}

function mutationTouchesSidebar(record) {
  if (record.target instanceof Element && record.target.closest('aside')) return true;
  return [...record.addedNodes, ...record.removedNodes].some((node) => (
    node instanceof Element && (node.matches('aside') || node.querySelector('aside'))
  ));
}

function scheduleMutationSync(records) {
  if (promptLauncher.mutationsCouldAffectLauncher(records)) promptLauncher.scheduleSync();
  const sidebarMutation = records.some(mutationTouchesSidebar);
  const dashboardMissing = !document.getElementById(dashboardDOM.elementIDs.page)
    || !document.getElementById(dashboardDOM.elementIDs.navButton);
  if (!sidebarMutation && !dashboardMissing) return;
  if (sidebarMutation) pendingSidebarMutation = true;
  if (mutationFrame !== undefined) return;
  mutationFrame = requestAnimationFrame(() => {
    mutationFrame = undefined;
    const shouldSyncUnread = pendingSidebarMutation;
    pendingSidebarMutation = false;
    const restoredPage = !document.getElementById(dashboardDOM.elementIDs.page);
    if (restoredPage) mountDashboardPage();
    if (!document.getElementById(dashboardDOM.elementIDs.navButton)) mountNavigationButton();
    if (dashboardIsOpen && restoredPage) openPage();
    attachPageToCodexContent();
    observeSidebar();
    if (shouldSyncUnread && syncUnreadFromSidebar()) requestDashboardRender();
  });
}

function mountNavigationButton() {
  const insertionPoint = codexHost.navigationInsertionPoint();
  if (!insertionPoint?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = dashboardDOM.elementIDs.navButton;
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
  const page = document.createElement('section');
  page.id = dashboardDOM.elementIDs.page;
  page.setAttribute('aria-label', 'Codex Thread Dashboard');
  page.innerHTML = `
    <div class="dashboard-shell">
      <header class="dashboard-header">
        <h1>Thread Dashboard</h1>
      </header>
      <div class="dashboard-notice" data-dashboard-notice role="alert" hidden></div>
      <section class="dashboard-running" data-running-summary aria-label="Running threads" hidden>
        <div class="dashboard-running-heading">
          <span class="dashboard-running-spinner has-count" role="status" aria-label="0 running threads" title="0 running threads"><span data-running-count aria-hidden="true">0</span></span>
          <h2>Running</h2>
        </div>
        <div class="dashboard-running-list" data-running-list></div>
      </section>
      <div class="dashboard-section-header">
        <div class="dashboard-toolbar">
          <div class="dashboard-filters" aria-label="Filter threads">
            <button type="button" data-filter="all" class="is-active">All <span class="dashboard-filter-count" data-filter-count="all">0</span></button>
            <button type="button" data-filter="unread">Unread <span class="dashboard-filter-count" data-filter-count="unread">0</span></button>
            <button type="button" data-filter="changedProjects">Changed projects <span class="dashboard-filter-count" data-filter-count="changedProjects" aria-label="Changed project count">0</span></button>
          </div>
          <label class="dashboard-search" aria-label="Search all threads">${threadMarkup.icon('search')}<input type="search" placeholder="Search threads" data-dashboard-search /></label>
          <div class="dashboard-view-options" aria-label="Group threads">
            <button type="button" data-view="projects" class="is-active" aria-pressed="true">Projects</button>
            <button type="button" data-view="recent" aria-pressed="false">Recent</button>
          </div>
        </div>
      </div>
      <p class="dashboard-loaded-summary" data-loaded-summary hidden></p>
      <main class="dashboard-list" data-thread-list></main>
      <button type="button" class="dashboard-load-more" data-load-more hidden>Load more threads</button>
    </div>`;
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.addEventListener('click', () => {
      filterMode = button.dataset.filter;
      saveDashboardPreferences();
      renderDashboard();
    });
  });
  page.querySelectorAll('[data-view]').forEach((button) => {
    button.addEventListener('click', () => {
      viewMode = button.dataset.view;
      saveDashboardPreferences();
      renderDashboard();
    });
  });
  page.querySelector('[data-dashboard-search]').addEventListener('input', (event) => {
    searchTerm = event.target.value;
    visibleThreadLimit = searchTerm.trim() ? Number.POSITIVE_INFINITY : threadPageSize;
    scheduleDashboardRender();
  });
  page.querySelector('[data-load-more]').addEventListener('click', () => {
    visibleThreadLimit += threadPageSize;
    renderDashboard();
  });
  page.querySelector('[data-thread-list]').addEventListener('click', (event) => {
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
  });
  page.querySelector('[data-thread-list]').addEventListener('keydown', openThreadFromKeyboardEvent);
  page.querySelector('[data-running-list]').addEventListener('click', openThreadFromEvent);
  page.querySelector('[data-running-list]').addEventListener('keydown', openThreadFromKeyboardEvent);
  codexHost.pageHost().append(page);
}

function openThreadFromEvent(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  const target = eventTarget?.closest('[data-open-thread]');
  if (!target) return;
  const thread = threads.find((item) => item.id === target.dataset.openThread);
  if (thread) openThread(thread);
}

function openThreadFromKeyboardEvent(event) {
  if (event.key !== 'Enter' && event.key !== ' ') return;
  const eventTarget = event.target instanceof Element ? event.target : null;
  if (!eventTarget?.matches('[data-open-thread]')) return;
  event.preventDefault();
  openThreadFromEvent(event);
}

function openPage() {
  const page = document.getElementById(dashboardDOM.elementIDs.page);
  if (!page) return;
  dashboardIsOpen = true;
  page.classList.add('is-open');
  document.documentElement.classList.add('codex-dashboard-open');
  document.getElementById(dashboardDOM.elementIDs.navButton)?.setAttribute('aria-current', 'page');
  if (dashboardNeedsRender) renderDashboard();
  else threadDashboardView.updateSidebarStatus(deriveDashboardState());
  scheduleUnreadSync(1500);
}

function closePage() {
  dashboardIsOpen = false;
  document.getElementById(dashboardDOM.elementIDs.page)?.classList.remove('is-open');
  document.documentElement.classList.remove('codex-dashboard-open');
  document.getElementById(dashboardDOM.elementIDs.navButton)?.removeAttribute('aria-current');
  scheduleUnreadSync();
}

function applySnapshot(nextSnapshot) {
  const snapshot = threadDashboardState.normalizeSnapshot(nextSnapshot);
  threads = snapshot.threads;
  unreadThreadIDs = new Set(
    threads.filter((thread) => thread.isUnread === true).map((thread) => thread.id),
  );
  syncUnreadFromSidebar();
  scheduleUnreadSync(1500);
  requestDashboardRender();
}

function ensureMounted() {
  if (!document.body) return false;
  if (!document.getElementById(dashboardDOM.elementIDs.style)) {
    const style = document.createElement('style');
    style.id = dashboardDOM.elementIDs.style;
    style.textContent = DASHBOARD_CSS;
    document.head.append(style);
  }
  const pageWasMissing = !document.getElementById(dashboardDOM.elementIDs.page);
  if (pageWasMissing) mountDashboardPage();
  if (!document.getElementById(dashboardDOM.elementIDs.navButton)) mountNavigationButton();
  attachPageToCodexContent();
  syncContentInset();
  promptLibrary.mount();
  if (dashboardIsOpen && pageWasMissing) openPage();

  if (!mutationObserver) {
    mutationObserver = new MutationObserver(scheduleMutationSync);
    mutationObserver.observe(document.body, { childList: true, subtree: true });
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
    document.getElementById(dashboardDOM.elementIDs.style)
      && document.getElementById(dashboardDOM.elementIDs.page)
      && document.getElementById(dashboardDOM.elementIDs.navButton)
  );
}

function destroy() {
  dashboardIsOpen = false;
  mutationObserver?.disconnect();
  resizeObserver?.disconnect();
  if (mutationFrame !== undefined) cancelAnimationFrame(mutationFrame);
  if (renderFrame !== undefined) cancelAnimationFrame(renderFrame);
  if (unreadSyncTimer !== undefined) clearTimeout(unreadSyncTimer);
  mutationObserver = undefined;
  resizeObserver = undefined;
  mutationFrame = undefined;
  renderFrame = undefined;
  unreadSyncTimer = undefined;
  pendingSidebarMutation = false;
  dashboardNeedsRender = true;
  observedSidebar = undefined;
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
  Object.values(dashboardDOM.elementIDs).forEach((id) => document.getElementById(id)?.remove());
  delete window.__codexDashboard;
}

return {
  ensureMounted,
  destroy,
  open: openPage,
  applySnapshot,
};
})();
