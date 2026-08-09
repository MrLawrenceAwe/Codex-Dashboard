const navigationEventTypes = ['pointerdown', 'mousedown', 'click'];

let threads = [];
let filterMode = 'all';
let searchTerm = '';
let viewMode = 'projects';
const collapsedProjects = new Set();
let mutationObserver;
let resizeObserver;
let observedSidebar;
let mutationFrame;
let unreadSyncTimer;
let pendingSidebarMutation = false;
let dashboardIsOpen = false;
let unreadThreadIDs = new Set();

function syncUnreadFromSidebar() {
  const readStates = codexUI.threadReadStates();
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
  if (syncUnreadFromSidebar()) renderDashboard();
}

function isThreadUnread(thread) {
  return unreadThreadIDs.has(thread.id);
}

function handleHostNavigation(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  if (eventTarget?.closest(`#${elementIDs.navButton}`)) {
    event.preventDefault();
    event.stopPropagation();
    if (event.type === 'click') openPage();
    return;
  }
  if (event.type !== 'click' || !dashboardIsOpen) return;
  if (eventTarget?.closest('aside') && !eventTarget.closest(`#${elementIDs.navButton}`)) closePage();
}

function iconMarkup(name) {
  const paths = {
    threads: '<path d="M8 6h12M8 12h12M8 18h12M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    project: '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h5l2 2H19.5A1.5 1.5 0 0 1 21 9.5v8A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"/>',
    arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/>',
    pin: '<path d="m9 3 6 0-1 6 3 3v2H7v-2l3-3zM12 14v7"/>',
    gitChanges: '<circle cx="6" cy="5" r="2"/><circle cx="18" cy="6" r="2"/><circle cx="6" cy="19" r="2"/><path d="M6 7v10M8 6h5a5 5 0 0 1 5 5v-3"/>',
    chevron: '<path d="m9 18 6-6-6-6"/>',
  };
  return `<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths[name]}</svg>`;
}

function formatRelativeTime(timestamp) {
  const seconds = Math.max(0, Math.round(Date.now() / 1000 - Number(timestamp || 0)));
  if (seconds < 60) return 'just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function deriveDashboardState() {
  return {
    runningThreads: threads.filter((thread) => thread.runState === 'running'),
    unreadCount: threads.filter(isThreadUnread).length,
    changedProjectPaths: new Set(
      threads
        .filter((thread) => thread.gitStatus === 'hasChanges')
        .map((thread) => String(thread.projectPath).trim()),
    ),
  };
}

function filterThreads({ changedProjectPaths }) {
  const query = searchTerm.trim().toLowerCase();
  return threads.filter((thread) => {
    const matchesFilter = filterMode === 'all'
      || (filterMode === 'unread' && isThreadUnread(thread))
      || (filterMode === 'changedProjects'
        && changedProjectPaths.has(String(thread.projectPath).trim()));
    const matchesSearch = !query || `${thread.title} ${thread.preview} ${thread.projectName} ${thread.projectPath}`.toLowerCase().includes(query);
    return matchesFilter && matchesSearch;
  });
}

function openThread(thread) {
  closePage();
  codexUI.navigateToThread(thread);
}

function renderThreadMarkup(thread, showProject = false) {
  const unread = isThreadUnread(thread);
  return `
    <article class="dashboard-thread" data-run-state="${escapeHTML(thread.runState)}" data-unread="${String(unread)}" data-thread-id="${escapeHTML(thread.id)}">
      <div class="dashboard-status-dot" title="${escapeHTML(thread.runState)}"></div>
      <div class="dashboard-thread-copy">
        <div class="dashboard-thread-title-row">
          ${unread ? '<span class="dashboard-unread-dot" role="status" aria-label="Unread response" title="Unread response"></span>' : ''}
          <h2>${escapeHTML(thread.title)}</h2>
          ${thread.isPinned ? `<span class="dashboard-pin" title="Pinned">${iconMarkup('pin')}</span>` : ''}
        </div>
        <p>${escapeHTML(thread.preview || 'No preview available')}</p>
        <div class="dashboard-meta">
          ${showProject ? `<span>${escapeHTML(thread.projectName)}</span>` : ''}
          <span>${formatRelativeTime(thread.sortTimestamp)}</span>
          ${thread.model ? `<span>${escapeHTML(thread.model)}</span>` : ''}
        </div>
      </div>
      <div class="dashboard-thread-actions">
        ${thread.runState === 'running' ? '<span class="dashboard-running-spinner" role="status" aria-label="Running" title="Running"></span>' : ''}
        <button type="button" data-open-thread="${escapeHTML(thread.id)}">Open ${iconMarkup('arrow')}</button>
      </div>
    </article>`;
}

function renderThreadListMarkup(visibleThreads) {
  if (viewMode === 'recent') {
    return [...visibleThreads]
      .sort((left, right) => Number(right.sortTimestamp || 0) - Number(left.sortTimestamp || 0))
      .map((thread) => renderThreadMarkup(thread, true))
      .join('');
  }
  const groups = new Map();
  visibleThreads.forEach((thread) => {
    const projectPath = String(thread.projectPath).trim();
    if (!groups.has(projectPath)) {
      groups.set(projectPath, { path: projectPath, name: thread.projectName, threads: [] });
    }
    groups.get(projectPath).threads.push(thread);
  });
  return [...groups.values()].map(({ path: projectPath, name: project, threads: projectThreads }, index) => {
    const isCollapsed = collapsedProjects.has(projectPath);
    const projectListID = `dashboard-project-${index}`;
    const runningCount = projectThreads.filter((thread) => thread.runState === 'running').length;
    return `
    <section class="dashboard-project-group${isCollapsed ? ' is-collapsed' : ''}" aria-label="${escapeHTML(project)} project">
      <header class="dashboard-project-heading">
        <button type="button" class="dashboard-project-toggle" data-project-toggle="${escapeHTML(projectPath)}" aria-expanded="${String(!isCollapsed)}" aria-controls="${projectListID}">
          <span class="dashboard-project-title">
            <span class="dashboard-project-chevron">${iconMarkup('chevron')}</span>
            <span class="dashboard-project-icon">${iconMarkup('project')}</span>
            <span class="dashboard-project-name">${escapeHTML(project)}</span>
            ${projectThreads.some((thread) => thread.gitStatus === 'hasChanges') ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${iconMarkup('gitChanges')}<span>Uncommitted</span></span>` : ''}
          </span>
          <span class="dashboard-project-summary">
            ${runningCount > 0 ? `<span class="dashboard-running-spinner has-count" role="status" aria-label="${runningCount} running ${runningCount === 1 ? 'thread' : 'threads'}" title="${runningCount} running ${runningCount === 1 ? 'thread' : 'threads'}"><span aria-hidden="true">${runningCount}</span></span>` : ''}
            <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'thread' : 'threads'}</span>
          </span>
        </button>
      </header>
      <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((thread) => renderThreadMarkup(thread)).join('')}</div>
    </section>`;
  }).join('');
}

function renderDashboard() {
  const state = deriveDashboardState();
  updateSidebarStatus(state);
  const page = document.getElementById(elementIDs.page);
  if (!page) return;
  const runningSummary = page.querySelector('[data-running-summary]');
  if (runningSummary) runningSummary.hidden = state.runningThreads.length === 0;
  const runningCount = page.querySelector('[data-running-count]');
  if (runningCount) {
    runningCount.textContent = String(state.runningThreads.length);
    const runningLabel = `${state.runningThreads.length} running ${state.runningThreads.length === 1 ? 'thread' : 'threads'}`;
    runningCount.parentElement?.setAttribute('aria-label', runningLabel);
    runningCount.parentElement?.setAttribute('title', runningLabel);
  }
  const runningList = page.querySelector('[data-running-list]');
  if (runningList) runningList.innerHTML = state.runningThreads
    .map((thread) => renderThreadMarkup(thread, true))
    .join('');
  page.querySelectorAll('[data-filter]').forEach((button) => {
    const isActive = button.dataset.filter === filterMode;
    button.classList.toggle('is-active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });
  const filterCounts = {
    all: threads.length,
    unread: state.unreadCount,
    changedProjects: state.changedProjectPaths.size,
  };
  page.querySelectorAll('[data-filter-count]').forEach((count) => {
    count.textContent = String(filterCounts[count.dataset.filterCount] ?? 0);
  });
  page.querySelectorAll('[data-view]').forEach((button) => {
    const isActive = button.dataset.view === viewMode;
    button.classList.toggle('is-active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });

  const visibleThreads = filterThreads(state);
  const list = page.querySelector('[data-thread-list]');
  if (!visibleThreads.length) {
    const emptyMessage = filterMode === 'unread' && !searchTerm.trim()
      ? 'You’re all caught up'
      : 'No threads found';
    list.innerHTML = `<div class="dashboard-empty"><strong>${emptyMessage}</strong></div>`;
    return;
  }
  list.innerHTML = renderThreadListMarkup(visibleThreads);
}

function syncContentInset() {
  const sidebar = codexUI.sidebar();
  const width = sidebar ? Math.max(0, sidebar.getBoundingClientRect().right) : 0;
  document.documentElement.style.setProperty('--codex-dashboard-content-left', `${Math.round(width)}px`);
}

function observeSidebar() {
  const sidebar = codexUI.sidebar();
  if (!resizeObserver || sidebar === observedSidebar) return;
  resizeObserver.disconnect();
  if (sidebar) resizeObserver.observe(sidebar);
  observedSidebar = sidebar;
}

function attachPageToCodexContent() {
  const page = document.getElementById(elementIDs.page);
  const pageHost = codexUI.pageHost();
  if (page && pageHost && page.parentElement !== pageHost) pageHost.append(page);
}

function mutationTouchesSidebar(record) {
  if (record.target instanceof Element && record.target.closest('aside')) return true;
  return [...record.addedNodes, ...record.removedNodes].some((node) => (
    node instanceof Element && (node.matches('aside') || node.querySelector('aside'))
  ));
}

function scheduleMutationSync(records) {
  schedulePromptMenuSync();
  const sidebarMutation = records.some(mutationTouchesSidebar);
  const dashboardMissing = !document.getElementById(elementIDs.page)
    || !document.getElementById(elementIDs.navButton);
  if (!sidebarMutation && !dashboardMissing) return;
  if (sidebarMutation) pendingSidebarMutation = true;
  if (mutationFrame !== undefined) return;
  mutationFrame = requestAnimationFrame(() => {
    mutationFrame = undefined;
    const shouldSyncUnread = pendingSidebarMutation;
    pendingSidebarMutation = false;
    const restoredPage = !document.getElementById(elementIDs.page);
    if (restoredPage) mountDashboardPage();
    if (!document.getElementById(elementIDs.navButton)) mountNavigationButton();
    if (dashboardIsOpen && restoredPage) openPage();
    attachPageToCodexContent();
    observeSidebar();
    if (shouldSyncUnread && syncUnreadFromSidebar()) renderDashboard();
  });
}

function mountNavigationButton() {
  const insertionPoint = codexUI.navigationInsertionPoint();
  if (!insertionPoint?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = elementIDs.navButton;
  button.type = 'button';
  button.className = insertionPoint.element.className;
  button.setAttribute('aria-label', 'Dashboard');
  button.innerHTML = `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${iconMarkup('threads')}</span>
      <span class="dashboard-nav-label">Dashboard</span>
    </div>
    <div class="dashboard-nav-status">
      <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="0 running threads" title="0 running threads" hidden><span data-navigation-running-count aria-hidden="true">0</span></span>
      <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread threads" hidden>0</strong>
    </div>`;
  if (insertionPoint.insertAfter) insertionPoint.element.after(button);
  else insertionPoint.element.parentElement.insertBefore(button, insertionPoint.element);
  updateSidebarStatus(deriveDashboardState());
  return true;
}

function mountDashboardPage() {
  const page = document.createElement('section');
  page.id = elementIDs.page;
  page.setAttribute('aria-label', 'Codex thread dashboard');
  page.innerHTML = `
    <div class="dashboard-shell">
      <header class="dashboard-header">
        <h1>Threads</h1>
      </header>
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
          <div class="dashboard-view-options" aria-label="Group threads">
            <button type="button" data-view="projects" class="is-active" aria-pressed="true">Projects</button>
            <button type="button" data-view="recent" aria-pressed="false">Recent</button>
          </div>
          <label class="dashboard-search" aria-label="Search loaded threads">${iconMarkup('search')}<input type="search" placeholder="Search threads" data-dashboard-search /></label>
        </div>
      </div>
      <main class="dashboard-list" data-thread-list></main>
    </div>`;
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.addEventListener('click', () => {
      filterMode = button.dataset.filter;
      renderDashboard();
    });
  });
  page.querySelectorAll('[data-view]').forEach((button) => {
    button.addEventListener('click', () => {
      viewMode = button.dataset.view;
      renderDashboard();
    });
  });
  page.querySelector('[data-dashboard-search]').addEventListener('input', (event) => {
    searchTerm = event.target.value;
    renderDashboard();
  });
  page.querySelector('[data-thread-list]').addEventListener('click', (event) => {
    const projectToggle = event.target.closest('[data-project-toggle]');
    if (projectToggle) {
      const projectPath = projectToggle.dataset.projectToggle;
      if (collapsedProjects.has(projectPath)) collapsedProjects.delete(projectPath);
      else collapsedProjects.add(projectPath);
      renderDashboard();
      return;
    }
    openThreadFromEvent(event);
  });
  page.querySelector('[data-running-list]').addEventListener('click', openThreadFromEvent);
  codexUI.pageHost().append(page);
}

function openThreadFromEvent(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  const button = eventTarget?.closest('[data-open-thread]');
  if (!button) return;
  const thread = threads.find((item) => item.id === button.dataset.openThread);
  if (thread) openThread(thread);
}

function openPage() {
  const page = document.getElementById(elementIDs.page);
  if (!page) return;
  dashboardIsOpen = true;
  page.classList.add('is-open');
  document.documentElement.classList.add('codex-dashboard-open');
  document.getElementById(elementIDs.navButton)?.setAttribute('aria-current', 'page');
  renderDashboard();
}

function closePage() {
  dashboardIsOpen = false;
  document.getElementById(elementIDs.page)?.classList.remove('is-open');
  document.documentElement.classList.remove('codex-dashboard-open');
  document.getElementById(elementIDs.navButton)?.removeAttribute('aria-current');
}

function updateSidebarStatus({ unreadCount, runningThreads }) {
  const unreadBadge = document.querySelector('[data-navigation-count]');
  if (unreadBadge) {
    unreadBadge.textContent = String(unreadCount);
    unreadBadge.hidden = unreadCount === 0;
    unreadBadge.setAttribute(
      'aria-label',
      `${unreadCount} unread ${unreadCount === 1 ? 'thread' : 'threads'}`,
    );
  }
  const spinner = document.querySelector('[data-navigation-running]');
  if (spinner) {
    const runningCount = runningThreads.length;
    const runningLabel = `${runningCount} running ${runningCount === 1 ? 'thread' : 'threads'}`;
    spinner.hidden = runningCount === 0;
    spinner.setAttribute('aria-label', runningLabel);
    spinner.setAttribute('title', runningLabel);
    const spinnerCount = spinner.querySelector('[data-navigation-running-count]');
    if (spinnerCount) spinnerCount.textContent = String(runningCount);
  }
}

function applySnapshot(nextSnapshot) {
  const nextThreads = Array.isArray(nextSnapshot?.threads) ? nextSnapshot.threads : [];
  threads = nextThreads;
  unreadThreadIDs = new Set(
    nextThreads.filter((thread) => thread.isUnread === true).map((thread) => thread.id),
  );
  syncUnreadFromSidebar();
  renderDashboard();
}

function ensureMounted() {
  if (!document.body) return false;
  if (!document.getElementById(elementIDs.style)) {
    const style = document.createElement('style');
    style.id = elementIDs.style;
    style.textContent = DASHBOARD_CSS;
    document.head.append(style);
  }
  const pageWasMissing = !document.getElementById(elementIDs.page);
  if (pageWasMissing) mountDashboardPage();
  if (!document.getElementById(elementIDs.navButton)) mountNavigationButton();
  attachPageToCodexContent();
  syncContentInset();
  mountPromptLibrary();
  if (dashboardIsOpen && pageWasMissing) openPage();

  if (!mutationObserver) {
    mutationObserver = new MutationObserver(scheduleMutationSync);
    mutationObserver.observe(document.body, { childList: true, subtree: true });
  }
  if (unreadSyncTimer === undefined) {
    unreadSyncTimer = window.setInterval(refreshUnreadFromSidebar, 250);
  }
  if (!resizeObserver && typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(syncContentInset);
    observeSidebar();
  }
  navigationEventTypes.forEach((type) => {
    document.addEventListener(type, handleHostNavigation, true);
  });
  return Boolean(
    document.getElementById(elementIDs.style)
      && document.getElementById(elementIDs.page)
      && document.getElementById(elementIDs.navButton)
  );
}

function destroy() {
  dashboardIsOpen = false;
  mutationObserver?.disconnect();
  resizeObserver?.disconnect();
  if (mutationFrame !== undefined) cancelAnimationFrame(mutationFrame);
  if (unreadSyncTimer !== undefined) clearInterval(unreadSyncTimer);
  mutationObserver = undefined;
  resizeObserver = undefined;
  mutationFrame = undefined;
  unreadSyncTimer = undefined;
  pendingSidebarMutation = false;
  observedSidebar = undefined;
  unmountPromptLibrary();
  navigationEventTypes.forEach((type) => {
    document.removeEventListener(type, handleHostNavigation, true);
  });
  document.documentElement.classList.remove('codex-dashboard-open');
  document.documentElement.style.removeProperty('--codex-dashboard-content-left');
  Object.values(elementIDs).forEach((id) => document.getElementById(id)?.remove());
  delete window.__codexDashboard;
}

window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  ensureMounted,
  destroy,
  open: openPage,
  applySnapshot,
};
return ensureMounted();
