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

const activeStatuses = new Set(['running', 'recent']);
const statusLabels = { running: 'Running', recent: 'Recent', idle: 'Idle' };
let tasks = [];
let totalTaskCount = 0;
let statusFilter = 'current';
let searchTerm = '';
let mutationObserver;
let resizeObserver;
let maintenanceTimer;
let isOpen = false;

function handleHostNavigation(event) {
  if (!isOpen) return;
  const target = event.target instanceof Element ? event.target : null;
  if (target?.closest('aside') && !target.closest(`#${ids.navButton}`)) closePage();
}

function iconSVG(name) {
  const paths = {
    tasks: '<path d="M8 6h12M8 12h12M8 18h12M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
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

function filteredTasks() {
  const query = searchTerm.trim().toLowerCase();
  return tasks.filter((task) => {
    const filterMatch = statusFilter === 'loaded'
      || (statusFilter === 'current' && activeStatuses.has(task.status))
      || task.status === statusFilter;
    const searchMatch = !query || `${task.title} ${task.preview} ${task.workspace}`.toLowerCase().includes(query);
    return filterMatch && searchMatch;
  });
}

function openTask(task) {
  const threadKey = `local:${task.id}`;
  const target = document.querySelector(
    `[data-app-action-sidebar-thread-id="${CSS.escape(threadKey)}"]`,
  );
  closePage();
  if (target) {
    target.click();
    return;
  }
  const link = document.createElement('a');
  link.href = `codex://threads/${encodeURIComponent(task.id)}`;
  link.hidden = true;
  document.body.append(link);
  link.click();
  link.remove();
}

function render() {
  const page = document.getElementById(ids.page);
  if (!page) return;
  const running = tasks.filter((task) => task.status === 'running').length;
  const recent = tasks.filter((task) => task.status === 'recent').length;
  page.querySelector('[data-count-running]').textContent = String(running);
  page.querySelector('[data-count-recent]').textContent = String(recent);
  page.querySelector('[data-count-total]').textContent = String(totalTaskCount);
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.classList.toggle('is-active', button.dataset.filter === statusFilter);
  });

  const visibleTasks = filteredTasks();
  const list = page.querySelector('[data-task-list]');
  if (!visibleTasks.length) {
    list.innerHTML = `<div class="dashboard-empty"><strong>No matching tasks</strong><span>Try another filter or search term.</span></div>`;
    return;
  }
  list.innerHTML = visibleTasks.map((task) => `
    <article class="dashboard-task" data-status="${escapeHTML(task.status)}" data-task-id="${escapeHTML(task.id)}">
      <div class="dashboard-status-dot" title="${escapeHTML(task.status)}"></div>
      <div class="dashboard-task-copy">
        <div class="dashboard-task-title-row">
          <h2>${escapeHTML(task.title)}</h2>
          ${task.isPinned ? `<span class="dashboard-pin" title="Pinned">${iconSVG('pin')}</span>` : ''}
        </div>
        <p>${escapeHTML(task.preview || 'No preview available')}</p>
        <div class="dashboard-meta">
          <span>${escapeHTML(task.workspace)}</span>
          <span>${relativeTime(task.updatedAt)}</span>
          ${task.model ? `<span>${escapeHTML(task.model)}</span>` : ''}
        </div>
      </div>
      <div class="dashboard-task-actions">
        <span class="dashboard-status-label">${statusLabels[task.status] ?? task.status}</span>
        <button type="button" data-open-task="${escapeHTML(task.id)}">Open ${iconSVG('arrow')}</button>
      </div>
    </article>`).join('');
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
      <span class="dashboard-nav-icon">${iconSVG('tasks')}</span>
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
  page.setAttribute('aria-label', 'Codex task dashboard');
  page.innerHTML = `
    <div class="dashboard-shell">
      <header class="dashboard-header">
        <div>
          <div class="dashboard-kicker">WORK OVERVIEW</div>
          <h1>Tasks</h1>
          <p>What Codex is working on, and what moved recently.</p>
        </div>
      </header>
      <section class="dashboard-stats" aria-label="Task summary">
        <div><strong data-count-running>0</strong><span>Running now</span></div>
        <div><strong data-count-recent>0</strong><span>Recently active</span></div>
        <div><strong data-count-total>0</strong><span>Total tasks</span></div>
      </section>
      <p class="dashboard-scope" data-dashboard-scope></p>
      <div class="dashboard-toolbar">
        <div class="dashboard-filters">
          <button type="button" data-filter="current" class="is-active">Current</button>
          <button type="button" data-filter="running">Running</button>
          <button type="button" data-filter="recent">Recent</button>
          <button type="button" data-filter="loaded">Loaded</button>
        </div>
        <label class="dashboard-search">${iconSVG('search')}<input type="search" placeholder="Search loaded tasks" data-dashboard-search /></label>
      </div>
      <main class="dashboard-list" data-task-list></main>
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
  page.querySelector('[data-task-list]').addEventListener('click', (event) => {
    const button = event.target.closest('[data-open-task]');
    if (!button) return;
    const task = tasks.find((item) => item.id === button.dataset.openTask);
    if (task) openTask(task);
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
  tasks = Array.isArray(nextSnapshot?.tasks) ? nextSnapshot.tasks : [];
  totalTaskCount = Number.isFinite(nextSnapshot?.totalTaskCount)
    ? Math.max(tasks.length, nextSnapshot.totalTaskCount)
    : tasks.length;
  const activeCount = tasks.filter((task) => activeStatuses.has(task.status)).length;
  const count = document.querySelector('[data-navigation-count]');
  if (count) count.textContent = String(activeCount);
  const scope = document.querySelector('[data-dashboard-scope]');
  if (scope) {
    scope.textContent = totalTaskCount > tasks.length
      ? `Showing the ${tasks.length} most recently active tasks. Search and filters cover these loaded tasks.`
      : `Showing all ${totalTaskCount} tasks.`;
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
    });
    mutationObserver.observe(document.body, { childList: true, subtree: true });
  }
  if (!resizeObserver && typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(syncContentInset);
    const sidebar = document.querySelector('aside.app-shell-left-panel, aside');
    if (sidebar) resizeObserver.observe(sidebar);
  }
  if (!maintenanceTimer) maintenanceTimer = window.setInterval(ensureMounted, 1500);
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
  if (maintenanceTimer) window.clearInterval(maintenanceTimer);
  mutationObserver = undefined;
  resizeObserver = undefined;
  maintenanceTimer = undefined;
  document.removeEventListener('click', handleHostNavigation, true);
  document.documentElement.classList.remove('codex-dashboard-open');
  document.documentElement.style.removeProperty('--codex-dashboard-content-left');
  Object.values(ids).forEach((id) => document.getElementById(id)?.remove());
  delete window.__codexDashboard;
}

window.__codexDashboard = { version: DASHBOARD_VERSION, ensureMounted, destroy, open: openPage, update };
return ensureMounted();
