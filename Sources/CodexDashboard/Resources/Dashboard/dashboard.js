const existing = window.__codexDashboard;
if (existing?.version === DASHBOARD_VERSION) {
  return existing.ensureMounted();
}
existing?.destroy?.();

const ids = {
  style: 'codex-dashboard-style',
  navButton: 'codex-dashboard-navigation',
  page: 'codex-dashboard-page',
};

let threads = [];
let statusFilter = 'all';
let searchTerm = '';
let viewMode = 'projects';
const collapsedProjects = new Set();
let mutationObserver;
let resizeObserver;
let observedSidebar;
let mutationFrame;
let pendingSidebarMutation = false;
let isOpen = false;
let unreadThreadIDs = new Set();

function sidebarUnreadState(row) {
  const fiberKey = Object.keys(row).find((key) => key.startsWith('__reactFiber$'));
  let fiber = fiberKey ? row[fiberKey] : null;
  while (fiber) {
    const props = fiber.memoizedProps || fiber.pendingProps;
    if (
      typeof props?.conversationId === 'string'
      && typeof props?.isUnread === 'boolean'
    ) {
      return { id: props.conversationId, unread: props.isUnread };
    }
    fiber = fiber.return;
  }
  return null;
}

function syncUnreadFromSidebar() {
  const nextUnreadThreadIDs = new Set();
  document.querySelectorAll('[data-app-action-sidebar-thread-id]').forEach((row) => {
    const state = sidebarUnreadState(row);
    if (state?.unread) nextUnreadThreadIDs.add(state.id);
  });
  const changed = nextUnreadThreadIDs.size !== unreadThreadIDs.size
    || [...nextUnreadThreadIDs].some((id) => !unreadThreadIDs.has(id));
  unreadThreadIDs = nextUnreadThreadIDs;
  return changed;
}

function isThreadUnread(thread) {
  return unreadThreadIDs.has(thread.id);
}

function handleHostNavigation(event) {
  const target = event.target instanceof Element ? event.target : null;
  if (target?.closest(`#${ids.navButton}`)) {
    event.preventDefault();
    event.stopPropagation();
    if (event.type === 'click') openPage();
    return;
  }
  if (event.type !== 'click' || !isOpen) return;
  if (target?.closest('aside') && !target.closest(`#${ids.navButton}`)) closePage();
}

function iconSVG(name) {
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

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[character]);
}

function relativeTime(timestamp) {
  const seconds = Math.max(0, Math.round(Date.now() / 1000 - Number(timestamp || 0)));
  if (seconds < 60) return 'just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function filteredThreads() {
  const query = searchTerm.trim().toLowerCase();
  return threads.filter((thread) => {
    const filterMatch = statusFilter === 'all'
      || (statusFilter === 'unread' && isThreadUnread(thread));
    const searchMatch = !query || `${thread.title} ${thread.preview} ${thread.workspace} ${thread.workspacePath}`.toLowerCase().includes(query);
    return filterMatch && searchMatch;
  });
}

function openThread(thread) {
  const threadKey = `local:${thread.id}`;
  const target = document.querySelector(
    `[data-app-action-sidebar-thread-id="${CSS.escape(threadKey)}"]`,
  );
  closePage();
  if (target) {
    target.click();
    return;
  }
  // A missing sidebar destination uses Codex's route bridge.
  window.dispatchEvent(new MessageEvent('message', {
    data: {
      type: 'navigate-to-route',
      path: `/local/${encodeURIComponent(thread.id)}`,
    },
    source: null,
  }));
}

function threadMarkup(thread, showProject = false) {
  const unread = isThreadUnread(thread);
  return `
    <article class="dashboard-thread" data-status="${escapeHTML(thread.status)}" data-unread="${String(unread)}" data-thread-id="${escapeHTML(thread.id)}">
      <div class="dashboard-status-dot" title="${escapeHTML(thread.status)}"></div>
      <div class="dashboard-thread-copy">
        <div class="dashboard-thread-title-row">
          ${unread ? '<span class="dashboard-unread-dot" role="status" aria-label="Unread response" title="Unread response"></span>' : ''}
          <h2>${escapeHTML(thread.title)}</h2>
          ${thread.isPinned ? `<span class="dashboard-pin" title="Pinned">${iconSVG('pin')}</span>` : ''}
        </div>
        <p>${escapeHTML(thread.preview || 'No preview available')}</p>
        <div class="dashboard-meta">
          ${showProject ? `<span>${escapeHTML(thread.workspace)}</span>` : ''}
          <span>${relativeTime(thread.updatedAt)}</span>
          ${thread.model ? `<span>${escapeHTML(thread.model)}</span>` : ''}
        </div>
      </div>
      <div class="dashboard-thread-actions">
        ${thread.status === 'running' ? '<span class="dashboard-running-spinner" role="status" aria-label="Running" title="Running"></span>' : ''}
        <button type="button" data-open-thread="${escapeHTML(thread.id)}">Open ${iconSVG('arrow')}</button>
      </div>
    </article>`;
}

function listMarkup(visibleThreads) {
  if (viewMode === 'updated') {
    return [...visibleThreads]
      .sort((left, right) => Number(right.updatedAt || 0) - Number(left.updatedAt || 0))
      .map((thread) => threadMarkup(thread, true))
      .join('');
  }
  const groups = new Map();
  visibleThreads.forEach((thread) => {
    const projectPath = String(thread.workspacePath).trim();
    if (!groups.has(projectPath)) groups.set(projectPath, { path: projectPath, name: thread.workspace, threads: [] });
    groups.get(projectPath).threads.push(thread);
  });
  return [...groups.values()].map(({ path: projectPath, name: project, threads: projectThreads }, index) => {
    const isCollapsed = collapsedProjects.has(projectPath);
    const projectListID = `dashboard-project-${index}`;
    return `
    <section class="dashboard-project-group${isCollapsed ? ' is-collapsed' : ''}" aria-label="${escapeHTML(project)} project">
      <header class="dashboard-project-heading">
        <button type="button" class="dashboard-project-toggle" data-project-toggle="${escapeHTML(projectPath)}" aria-expanded="${String(!isCollapsed)}" aria-controls="${projectListID}">
          <span class="dashboard-project-title">
            <span class="dashboard-project-chevron">${iconSVG('chevron')}</span>
            <span class="dashboard-project-icon">${iconSVG('project')}</span>
            <span class="dashboard-project-name">${escapeHTML(project)}</span>
            ${projectThreads.some((thread) => thread.gitStatus === 'modified') ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${iconSVG('gitChanges')}<span>Uncommitted</span></span>` : ''}
          </span>
          <span class="dashboard-project-summary">
            ${projectThreads.some((thread) => thread.status === 'running') ? '<span class="dashboard-running-spinner" role="status" aria-label="Thread running" title="Thread running"></span>' : ''}
            <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'thread' : 'threads'}</span>
          </span>
        </button>
      </header>
      <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((thread) => threadMarkup(thread)).join('')}</div>
    </section>`;
  }).join('');
}

function render() {
  updateNavigationStatus();
  const page = document.getElementById(ids.page);
  if (!page) return;
  const runningThreads = threads.filter((thread) => thread.status === 'running');
  const unread = threads.filter(isThreadUnread).length;
  const runningSummary = page.querySelector('[data-running-summary]');
  if (runningSummary) runningSummary.hidden = runningThreads.length === 0;
  const runningList = page.querySelector('[data-running-list]');
  if (runningList) runningList.innerHTML = runningThreads
    .map((thread) => threadMarkup(thread, true))
    .join('');
  page.querySelectorAll('[data-filter]').forEach((button) => {
    const isActive = button.dataset.filter === statusFilter;
    button.classList.toggle('is-active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });
  const filterCounts = {
    all: threads.length,
    unread,
  };
  page.querySelectorAll('[data-filter-count]').forEach((count) => {
    count.textContent = String(filterCounts[count.dataset.filterCount] ?? 0);
  });
  page.querySelectorAll('[data-view]').forEach((button) => {
    const isActive = button.dataset.view === viewMode;
    button.classList.toggle('is-active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });

  const visibleThreads = filteredThreads();
  page.querySelector('[data-visible-summary]').textContent = `${visibleThreads.length} ${visibleThreads.length === 1 ? 'thread' : 'threads'}`;
  const list = page.querySelector('[data-thread-list]');
  if (!visibleThreads.length) {
    const emptyMessage = statusFilter === 'unread' && !searchTerm.trim()
      ? 'You’re all caught up'
      : 'No threads found';
    list.innerHTML = `<div class="dashboard-empty"><strong>${emptyMessage}</strong></div>`;
    return;
  }
  list.innerHTML = listMarkup(visibleThreads);
}

function findSidebarReference() {
  const navigation = document.querySelector('nav, [role="navigation"]');
  if (!navigation) return null;
  const buttons = [...navigation.querySelectorAll('button')];
  const newChat = buttons.find((button) => button.textContent.trim() === 'New chat');
  const newChatRow = newChat?.closest('.sidebar-item');
  if (newChatRow?.parentElement) return { element: newChatRow, insertAfter: true };
  const destination = buttons.find((button) => button.textContent.trim() === 'Pull requests')
    || buttons.find((button) => button.classList.contains('sidebar-item'));
  return destination?.parentElement ? { element: destination, insertAfter: false } : null;
}

function syncContentInset() {
  const sidebar = document.querySelector('aside.app-shell-left-panel, aside');
  const width = sidebar ? Math.max(0, sidebar.getBoundingClientRect().right) : 0;
  document.documentElement.style.setProperty('--codex-dashboard-content-left', `${Math.round(width)}px`);
}

function observeSidebar() {
  const sidebar = document.querySelector('aside.app-shell-left-panel, aside');
  if (!resizeObserver || sidebar === observedSidebar) return;
  resizeObserver.disconnect();
  if (sidebar) resizeObserver.observe(sidebar);
  observedSidebar = sidebar;
}

function syncPageHost() {
  const page = document.getElementById(ids.page);
  const sidebar = document.querySelector('aside.app-shell-left-panel, aside');
  const pageHost = sidebar?.parentElement;
  if (page && pageHost && page.parentElement !== pageHost) pageHost.append(page);
}

function mutationTouchesSidebar(record) {
  if (record.target instanceof Element && record.target.closest('aside')) return true;
  return [...record.addedNodes, ...record.removedNodes].some((node) => (
    node instanceof Element && (node.matches('aside') || node.querySelector('aside'))
  ));
}

function scheduleMutationSync(records) {
  const sidebarMutation = records.some(mutationTouchesSidebar);
  const dashboardMissing = !document.getElementById(ids.page)
    || !document.getElementById(ids.navButton);
  if (!sidebarMutation && !dashboardMissing) return;
  if (sidebarMutation) pendingSidebarMutation = true;
  if (mutationFrame !== undefined) return;
  mutationFrame = requestAnimationFrame(() => {
    mutationFrame = undefined;
    const shouldSyncUnread = pendingSidebarMutation;
    pendingSidebarMutation = false;
    const restoredPage = !document.getElementById(ids.page);
    if (restoredPage) createPage();
    if (!document.getElementById(ids.navButton)) createNavigation();
    if (isOpen && restoredPage) openPage();
    syncPageHost();
    observeSidebar();
    if (shouldSyncUnread && syncUnreadFromSidebar()) render();
  });
}

function createNavigation() {
  const reference = findSidebarReference();
  if (!reference?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = ids.navButton;
  button.type = 'button';
  button.className = reference.element.className;
  button.setAttribute('aria-label', 'Dashboard');
  button.innerHTML = `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${iconSVG('threads')}</span>
      <span class="dashboard-nav-label">Dashboard</span>
    </div>
    <div class="dashboard-nav-status">
      <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="Threads running" title="Threads running" hidden></span>
      <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread threads" hidden>0</strong>
    </div>`;
  if (reference.insertAfter) reference.element.after(button);
  else reference.element.parentElement.insertBefore(button, reference.element);
  updateNavigationStatus();
  return true;
}

function createPage() {
  const page = document.createElement('section');
  page.id = ids.page;
  page.setAttribute('aria-label', 'Codex thread dashboard');
  page.innerHTML = `
    <div class="dashboard-shell">
      <header class="dashboard-header">
        <h1>Threads</h1>
      </header>
      <section class="dashboard-running" data-running-summary aria-label="Running threads" hidden>
        <div class="dashboard-running-heading">
          <span class="dashboard-running-spinner" role="status" aria-label="Running threads" title="Running threads"></span>
          <h2>Running</h2>
        </div>
        <div class="dashboard-running-list" data-running-list></div>
      </section>
      <div class="dashboard-section-header">
        <div class="dashboard-section-title">
          <p data-visible-summary>0 threads</p>
        </div>
        <div class="dashboard-toolbar">
          <div class="dashboard-filters" aria-label="Filter threads">
            <button type="button" data-filter="all" class="is-active">All <span class="dashboard-filter-count" data-filter-count="all">0</span></button>
            <button type="button" data-filter="unread">Unread <span class="dashboard-filter-count" data-filter-count="unread">0</span></button>
          </div>
          <div class="dashboard-view-options" aria-label="View threads">
            <button type="button" data-view="projects" class="is-active" aria-pressed="true">Projects</button>
            <button type="button" data-view="updated" aria-pressed="false">Last updated</button>
          </div>
          <label class="dashboard-search" aria-label="Search loaded threads">${iconSVG('search')}<input type="search" placeholder="Search threads" data-dashboard-search /></label>
        </div>
      </div>
      <main class="dashboard-list" data-thread-list></main>
    </div>`;
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.addEventListener('click', () => {
      statusFilter = button.dataset.filter;
      render();
    });
  });
  page.querySelectorAll('[data-view]').forEach((button) => {
    button.addEventListener('click', () => {
      viewMode = button.dataset.view;
      render();
    });
  });
  page.querySelector('[data-dashboard-search]').addEventListener('input', (event) => {
    searchTerm = event.target.value;
    render();
  });
  page.querySelector('[data-thread-list]').addEventListener('click', (event) => {
    const projectToggle = event.target.closest('[data-project-toggle]');
    if (projectToggle) {
      const projectPath = projectToggle.dataset.projectToggle;
      if (collapsedProjects.has(projectPath)) collapsedProjects.delete(projectPath);
      else collapsedProjects.add(projectPath);
      render();
      return;
    }
    const button = event.target.closest('[data-open-thread]');
    if (!button) return;
    const thread = threads.find((item) => item.id === button.dataset.openThread);
    if (thread) openThread(thread);
  });
  page.querySelector('[data-running-list]').addEventListener('click', (event) => {
    const button = event.target.closest('[data-open-thread]');
    if (!button) return;
    const thread = threads.find((item) => item.id === button.dataset.openThread);
    if (thread) openThread(thread);
  });
  const sidebar = document.querySelector('aside.app-shell-left-panel, aside');
  const pageHost = sidebar?.parentElement || document.body;
  pageHost.append(page);
}

function openPage() {
  const page = document.getElementById(ids.page);
  if (!page) return;
  isOpen = true;
  page.classList.add('is-open');
  document.documentElement.classList.add('codex-dashboard-open');
  document.getElementById(ids.navButton)?.setAttribute('aria-current', 'page');
  render();
}

function closePage() {
  isOpen = false;
  document.getElementById(ids.page)?.classList.remove('is-open');
  document.documentElement.classList.remove('codex-dashboard-open');
  document.getElementById(ids.navButton)?.removeAttribute('aria-current');
}

function updateNavigationStatus() {
  const unreadCount = threads.filter(isThreadUnread).length;
  const hasRunningThreads = threads.some((thread) => thread.status === 'running');
  const count = document.querySelector('[data-navigation-count]');
  if (count) {
    count.textContent = String(unreadCount);
    count.hidden = unreadCount === 0;
    count.setAttribute(
      'aria-label',
      `${unreadCount} unread ${unreadCount === 1 ? 'thread' : 'threads'}`,
    );
  }
  const spinner = document.querySelector('[data-navigation-running]');
  if (spinner) spinner.hidden = !hasRunningThreads;
}

function update(nextSnapshot) {
  const nextThreads = Array.isArray(nextSnapshot?.threads) ? nextSnapshot.threads : [];
  threads = nextThreads;
  syncUnreadFromSidebar();
  render();
}

function ensureMounted() {
  if (!document.body) return false;
  if (!document.getElementById(ids.style)) {
    const style = document.createElement('style');
    style.id = ids.style;
    style.textContent = DASHBOARD_CSS;
    document.head.append(style);
  }
  const pageWasMissing = !document.getElementById(ids.page);
  if (pageWasMissing) createPage();
  if (!document.getElementById(ids.navButton)) createNavigation();
  syncPageHost();
  syncContentInset();
  if (isOpen && pageWasMissing) openPage();

  if (!mutationObserver) {
    mutationObserver = new MutationObserver(scheduleMutationSync);
    mutationObserver.observe(document.body, { childList: true, subtree: true });
  }
  if (!resizeObserver && typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(syncContentInset);
    observeSidebar();
  }
  document.addEventListener('pointerdown', handleHostNavigation, true);
  document.addEventListener('mousedown', handleHostNavigation, true);
  document.addEventListener('click', handleHostNavigation, true);
  return Boolean(
    document.getElementById(ids.style)
      && document.getElementById(ids.page)
      && document.getElementById(ids.navButton)
  );
}

function destroy() {
  isOpen = false;
  mutationObserver?.disconnect();
  resizeObserver?.disconnect();
  if (mutationFrame !== undefined) cancelAnimationFrame(mutationFrame);
  mutationObserver = undefined;
  resizeObserver = undefined;
  mutationFrame = undefined;
  pendingSidebarMutation = false;
  observedSidebar = undefined;
  document.removeEventListener('pointerdown', handleHostNavigation, true);
  document.removeEventListener('mousedown', handleHostNavigation, true);
  document.removeEventListener('click', handleHostNavigation, true);
  document.documentElement.classList.remove('codex-dashboard-open');
  document.documentElement.style.removeProperty('--codex-dashboard-content-left');
  Object.values(ids).forEach((id) => document.getElementById(id)?.remove());
  delete window.__codexDashboard;
}

window.__codexDashboard = { version: DASHBOARD_VERSION, ensureMounted, destroy, open: openPage, update };
return ensureMounted();
