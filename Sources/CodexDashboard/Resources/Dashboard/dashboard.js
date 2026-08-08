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
let totalThreadCount = 0;
let statusFilter = 'all';
let searchTerm = '';
let groupByProject = true;
let mutationObserver;
let resizeObserver;
let observedSidebar;
let isOpen = false;

function handleHostNavigation(event) {
  if (!isOpen) return;
  const target = event.target instanceof Element ? event.target : null;
  if (target?.closest('aside') && !target.closest(`#${ids.navButton}`)) closePage();
}

function iconSVG(name) {
  const paths = {
    threads: '<path d="M8 6h12M8 12h12M8 18h12M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    project: '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h5l2 2H19.5A1.5 1.5 0 0 1 21 9.5v8A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"/>',
    arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/>',
    pin: '<path d="m9 3 6 0-1 6 3 3v2H7v-2l3-3zM12 14v7"/>',
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
      || (statusFilter === 'running' && thread.status === 'running')
      || (statusFilter === 'pinned' && thread.isPinned);
    const searchMatch = !query || `${thread.title} ${thread.preview} ${thread.workspace}`.toLowerCase().includes(query);
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
  const link = document.createElement('a');
  link.href = `codex://threads/${encodeURIComponent(thread.id)}`;
  link.hidden = true;
  document.body.append(link);
  link.click();
  link.remove();
}

function threadMarkup(thread, grouped = false) {
  return `
    <article class="dashboard-thread" data-status="${escapeHTML(thread.status)}" data-thread-id="${escapeHTML(thread.id)}">
      <div class="dashboard-status-dot" title="${escapeHTML(thread.status)}"></div>
      <div class="dashboard-thread-copy">
        <div class="dashboard-thread-title-row">
          <h2>${escapeHTML(thread.title)}</h2>
          ${thread.isPinned ? `<span class="dashboard-pin" title="Pinned">${iconSVG('pin')}</span>` : ''}
        </div>
        <p>${escapeHTML(thread.preview || 'No preview available')}</p>
        <div class="dashboard-meta">
          ${grouped ? '' : `<span>${escapeHTML(thread.workspace)}</span>`}
          <span>${relativeTime(thread.updatedAt)}</span>
          ${thread.model ? `<span>${escapeHTML(thread.model)}</span>` : ''}
        </div>
      </div>
      <div class="dashboard-thread-actions">
        ${thread.status === 'running' ? '<span class="dashboard-status-label">Running</span>' : ''}
        <button type="button" data-open-thread="${escapeHTML(thread.id)}">Open ${iconSVG('arrow')}</button>
      </div>
    </article>`;
}

function listMarkup(visibleThreads) {
  if (!groupByProject) return visibleThreads.map((thread) => threadMarkup(thread)).join('');
  const groups = new Map();
  visibleThreads.forEach((thread) => {
    const project = String(thread.workspace || 'Unassigned project').trim() || 'Unassigned project';
    if (!groups.has(project)) groups.set(project, []);
    groups.get(project).push(thread);
  });
  return [...groups].map(([project, projectThreads]) => `
    <section class="dashboard-project-group" aria-label="${escapeHTML(project)} project">
      <header class="dashboard-project-heading">
        <div class="dashboard-project-title"><span class="dashboard-project-icon">${iconSVG('project')}</span><h3>${escapeHTML(project)}</h3></div>
        <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'thread' : 'threads'}</span>
      </header>
      <div class="dashboard-project-list">${projectThreads.map((thread) => threadMarkup(thread, true)).join('')}</div>
    </section>`).join('');
}

function render() {
  const page = document.getElementById(ids.page);
  if (!page) return;
  const running = threads.filter((thread) => thread.status === 'running').length;
  const pinned = threads.filter((thread) => thread.isPinned).length;
  page.querySelector('[data-count-running]').textContent = String(running);
  page.querySelector('[data-count-pinned]').textContent = String(pinned);
  page.querySelector('[data-count-total]').textContent = String(totalThreadCount);
  page.querySelectorAll('[data-filter]').forEach((button) => {
    const isActive = button.dataset.filter === statusFilter;
    button.classList.toggle('is-active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });
  const filterCounts = {
    all: threads.length,
    running,
    pinned,
  };
  page.querySelectorAll('[data-filter-count]').forEach((count) => {
    count.textContent = String(filterCounts[count.dataset.filterCount] ?? 0);
  });

  const visibleThreads = filteredThreads();
  page.querySelector('[data-group-toggle]').classList.toggle('is-active', groupByProject);
  page.querySelector('[data-group-toggle]').setAttribute('aria-pressed', String(groupByProject));
  page.querySelector('[data-group-toggle-label]').textContent = groupByProject ? 'Grouped by project' : 'Group by project';
  page.querySelector('[data-visible-summary]').textContent = `${visibleThreads.length} ${visibleThreads.length === 1 ? 'thread' : 'threads'} in this view`;
  const list = page.querySelector('[data-thread-list]');
  if (!visibleThreads.length) {
    list.innerHTML = `<div class="dashboard-empty"><strong>No matching threads</strong><span>Try another filter or search term.</span></div>`;
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
    <strong class="dashboard-nav-count" data-navigation-count>0</strong>`;
  button.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    openPage();
  });
  if (reference.insertAfter) reference.element.after(button);
  else reference.element.parentElement.insertBefore(button, reference.element);
  return true;
}

function createPage() {
  const page = document.createElement('section');
  page.id = ids.page;
  page.setAttribute('aria-label', 'Codex thread dashboard');
  page.innerHTML = `
    <div class="dashboard-shell">
      <header class="dashboard-header">
        <div>
          <div class="dashboard-kicker">WORK OVERVIEW</div>
          <h1>Threads</h1>
          <p>Your Codex conversations across every workspace.</p>
        </div>
        <div class="dashboard-live-pill">Local overview</div>
      </header>
      <section class="dashboard-stats" aria-label="Thread summary">
        <div class="dashboard-stat" data-tone="running">
          <span class="dashboard-stat-heading"><i class="dashboard-stat-indicator"></i>Running now</span>
          <strong data-count-running>0</strong>
          <small>Active responses</small>
        </div>
        <div class="dashboard-stat" data-tone="pinned">
          <span class="dashboard-stat-heading"><i class="dashboard-stat-indicator"></i>Pinned</span>
          <strong data-count-pinned>0</strong>
          <small>Saved for quick access</small>
        </div>
        <div class="dashboard-stat">
          <span class="dashboard-stat-heading"><i class="dashboard-stat-indicator"></i>Total threads</span>
          <strong data-count-total>0</strong>
          <small>Across your workspaces</small>
        </div>
      </section>
      <p class="dashboard-scope" data-dashboard-scope></p>
      <div class="dashboard-section-header">
        <div class="dashboard-section-title">
          <h2>Thread list</h2>
          <p data-visible-summary>0 threads in this view</p>
        </div>
        <div class="dashboard-toolbar">
          <div class="dashboard-filters" aria-label="Filter threads">
            <button type="button" data-filter="all" class="is-active">All <span class="dashboard-filter-count" data-filter-count="all">0</span></button>
            <button type="button" data-filter="running">Running <span class="dashboard-filter-count" data-filter-count="running">0</span></button>
            <button type="button" data-filter="pinned">Pinned <span class="dashboard-filter-count" data-filter-count="pinned">0</span></button>
          </div>
          <label class="dashboard-search" aria-label="Search loaded threads">${iconSVG('search')}<input type="search" placeholder="Search threads" data-dashboard-search /></label>
          <button type="button" class="dashboard-view-toggle" data-group-toggle aria-pressed="true">${iconSVG('project')}<span data-group-toggle-label>Grouped by project</span></button>
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
  page.querySelector('[data-dashboard-search]').addEventListener('input', (event) => {
    searchTerm = event.target.value;
    render();
  });
  page.querySelector('[data-group-toggle]').addEventListener('click', () => {
    groupByProject = !groupByProject;
    render();
  });
  page.querySelector('[data-thread-list]').addEventListener('click', (event) => {
    const button = event.target.closest('[data-open-thread]');
    if (!button) return;
    const thread = threads.find((item) => item.id === button.dataset.openThread);
    if (thread) openThread(thread);
  });
  document.body.append(page);
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

function update(nextSnapshot) {
  threads = Array.isArray(nextSnapshot?.threads) ? nextSnapshot.threads : [];
  totalThreadCount = Number.isFinite(nextSnapshot?.totalThreadCount)
    ? Math.max(threads.length, nextSnapshot.totalThreadCount)
    : threads.length;
  const activeCount = threads.filter((thread) => thread.status === 'running').length;
  const count = document.querySelector('[data-navigation-count]');
  if (count) count.textContent = String(activeCount);
  const scope = document.querySelector('[data-dashboard-scope]');
  if (scope) {
    scope.textContent = totalThreadCount > threads.length
      ? `Showing the ${threads.length} most recently updated threads. Search and filters cover these loaded threads.`
      : `Showing all ${totalThreadCount} threads.`;
  }
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
  syncContentInset();
  if (isOpen && pageWasMissing) openPage();

  if (!mutationObserver) {
    mutationObserver = new MutationObserver(() => {
      const restoredPage = !document.getElementById(ids.page);
      if (restoredPage) createPage();
      if (!document.getElementById(ids.navButton)) createNavigation();
      if (isOpen && restoredPage) openPage();
      observeSidebar();
      syncContentInset();
    });
    mutationObserver.observe(document.body, { childList: true, subtree: true });
  }
  if (!resizeObserver && typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(syncContentInset);
    observeSidebar();
  }
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
  mutationObserver = undefined;
  resizeObserver = undefined;
  observedSidebar = undefined;
  document.removeEventListener('click', handleHostNavigation, true);
  document.documentElement.classList.remove('codex-dashboard-open');
  document.documentElement.style.removeProperty('--codex-dashboard-content-left');
  Object.values(ids).forEach((id) => document.getElementById(id)?.remove());
  delete window.__codexDashboard;
}

window.__codexDashboard = { version: DASHBOARD_VERSION, ensureMounted, destroy, open: openPage, update };
return ensureMounted();
