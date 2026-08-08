const existing = window.__codexDashboard;
if (existing?.version === CANVAS_VERSION) {
  existing.ensureMounted();
  return true;
}
existing?.destroy?.();
window.__codexCanvas?.destroy?.();
document.documentElement.classList.remove('cc-canvas-open', 'cc-focus-mode');
document.getElementById('codex-canvas-launcher')?.remove();
document.getElementById('codex-canvas-page')?.remove();

const ids = {
  style: 'codex-dashboard-style',
  navigation: 'codex-dashboard-navigation',
  page: 'codex-dashboard-page',
};

let taskData = [];
let selectedFilter = 'active';
let searchTerm = '';
let mutationObserver;
let resizeObserver;
let maintenanceTimer;
let isOpen = false;

function handleHostNavigation(event) {
  if (!isOpen) return;
  const target = event.target instanceof Element ? event.target : null;
  if (target?.closest('aside') && !target.closest(`#${ids.navigation}`)) closePage();
}

function icon(name) {
  const paths = {
    tasks: '<path d="M8 6h12M8 12h12M8 18h12M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    close: '<path d="M6 6l12 12M18 6L6 18"/>',
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

function visibleTasks() {
  const query = searchTerm.trim().toLowerCase();
  return taskData.filter((task) => {
    const filterMatch = selectedFilter === 'all'
      || (selectedFilter === 'active' && ['running', 'recent'].includes(task.status))
      || task.status === selectedFilter;
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
  const running = taskData.filter((task) => task.status === 'running').length;
  const recent = taskData.filter((task) => task.status === 'recent').length;
  page.querySelector('[data-count-running]').textContent = String(running);
  page.querySelector('[data-count-recent]').textContent = String(recent);
  page.querySelector('[data-count-total]').textContent = String(taskData.length);
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.classList.toggle('is-active', button.dataset.filter === selectedFilter);
  });

  const tasks = visibleTasks();
  const list = page.querySelector('[data-task-list]');
  if (!tasks.length) {
    list.innerHTML = `<div class="dashboard-empty"><strong>No matching tasks</strong><span>Try another filter or search term.</span></div>`;
    return;
  }
  list.innerHTML = tasks.map((task) => `
    <article class="dashboard-task" data-status="${escapeHTML(task.status)}" data-task-id="${escapeHTML(task.id)}">
      <div class="dashboard-status-dot" title="${escapeHTML(task.status)}"></div>
      <div class="dashboard-task-copy">
        <div class="dashboard-task-title-row">
          <h2>${escapeHTML(task.title)}</h2>
          ${task.isPinned ? `<span class="dashboard-pin" title="Pinned">${icon('pin')}</span>` : ''}
        </div>
        <p>${escapeHTML(task.preview || 'No preview available')}</p>
        <div class="dashboard-meta">
          <span>${escapeHTML(task.workspace)}</span>
          <span>${relativeTime(task.updatedAt)}</span>
          ${task.model ? `<span>${escapeHTML(task.model)}</span>` : ''}
        </div>
      </div>
      <div class="dashboard-task-actions">
        <span class="dashboard-status-label">${task.status === 'running' ? 'Running' : task.status === 'recent' ? 'Recent' : 'Idle'}</span>
        <button type="button" data-open-task="${escapeHTML(task.id)}">Open ${icon('arrow')}</button>
      </div>
    </article>`).join('');
  list.querySelectorAll('[data-open-task]').forEach((button) => {
    button.addEventListener('click', () => {
      const task = taskData.find((item) => item.id === button.dataset.openTask);
      if (task) openTask(task);
    });
  });
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
  button.id = ids.navigation;
  button.type = 'button';
  button.className = reference.element.className;
  button.setAttribute('aria-label', 'Dashboard');
  button.innerHTML = `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${icon('tasks')}</span>
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
        <div><strong data-count-total>0</strong><span>Visible tasks</span></div>
      </section>
      <div class="dashboard-toolbar">
        <div class="dashboard-filters">
          <button type="button" data-filter="active" class="is-active">Active</button>
          <button type="button" data-filter="running">Running</button>
          <button type="button" data-filter="recent">Recent</button>
          <button type="button" data-filter="all">All</button>
        </div>
        <label class="dashboard-search">${icon('search')}<input type="search" placeholder="Search tasks" data-dashboard-search /></label>
      </div>
      <main class="dashboard-list" data-task-list></main>
      <div class="dashboard-feedback" data-dashboard-feedback aria-live="polite"></div>
    </div>`;
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.addEventListener('click', () => {
      selectedFilter = button.dataset.filter;
      render();
    });
  });
  page.querySelector('[data-dashboard-search]').addEventListener('input', (event) => {
    searchTerm = event.target.value;
    render();
  });
  document.body.append(page);
}

function openPage() {
  const page = document.getElementById(ids.page);
  if (!page) return;
  isOpen = true;
  page.classList.add('is-open');
  document.documentElement.classList.add('codex-dashboard-open');
  document.getElementById(ids.navigation)?.setAttribute('aria-current', 'page');
  render();
}

function closePage() {
  isOpen = false;
  document.getElementById(ids.page)?.classList.remove('is-open');
  document.documentElement.classList.remove('codex-dashboard-open');
  document.getElementById(ids.navigation)?.removeAttribute('aria-current');
}

function update(tasks) {
  taskData = Array.isArray(tasks) ? tasks : [];
  const activeCount = taskData.filter((task) => ['running', 'recent'].includes(task.status)).length;
  const count = document.querySelector('[data-navigation-count]');
  if (count) count.textContent = String(activeCount);
  render();
}

function ensureMounted() {
  if (!document.body) return false;
  if (!document.getElementById(ids.style)) {
    const style = document.createElement('style');
    style.id = ids.style;
    style.textContent = CANVAS_CSS;
    document.head.append(style);
  }
  const pageWasMissing = !document.getElementById(ids.page);
  if (pageWasMissing) createPage();
  if (!document.getElementById(ids.navigation)) createNavigation();
  syncContentInset();
  if (isOpen && pageWasMissing) openPage();

  if (!mutationObserver) {
    mutationObserver = new MutationObserver(() => {
      const restoredPage = !document.getElementById(ids.page);
      if (restoredPage) createPage();
      if (!document.getElementById(ids.navigation)) createNavigation();
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
  return true;
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

window.__codexDashboard = { version: CANVAS_VERSION, ensureMounted, destroy, open: openPage, close: closePage, update };
return ensureMounted();
