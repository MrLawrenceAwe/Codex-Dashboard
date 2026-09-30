function createSidebarThreadTodoActions({ findThread, getItems, addTodo }) {
  const selector = '[data-app-action-sidebar-thread-id]';
  const events = ['pointerdown', 'mousedown', 'click', 'keydown'];
  let sidebar;
  let observer;
  let started = false;
  let destroyed = false;
  let notice;
  let noticeTimer;
  const pending = new Set();

  function reference(row) {
    const sidebarID = row.getAttribute('data-app-action-sidebar-thread-id') || '';
    if (!sidebarID.startsWith('local:')) return null;
    const id = sidebarID.slice('local:'.length);
    const thread = findThread(id);
    const title = String(thread?.title
      || row.querySelector('[data-thread-title-trigger], [data-marquee-text]')?.textContent
      || [...row.childNodes].filter((node) => !(node instanceof Element)
        || !node.matches('[data-codex-thread-todo], button, svg'))
        .map((node) => node.textContent).join('')).trim();
    return id && title ? { id, title, projectPath: thread?.projectPath } : null;
  }

  function alreadyAdded(id) {
    return getItems().some((item) => !item.completed && item.thread?.id === id);
  }

  function refresh() {
    const writeProtected = Boolean(todoStore.writeProtectionReason());
    sidebar?.querySelectorAll(selector).forEach((row) => {
      const thread = reference(row);
      let button = row.querySelector('[data-codex-thread-todo]');
      if (!thread) { button?.remove(); return; }
      if (!button) {
        button = document.createElement('button');
        button.type = 'button';
        button.dataset.codexThreadTodo = '';
        row.append(button);
      }
      const added = alreadyAdded(thread.id);
      const label = pending.has(thread.id) ? 'Adding to To-dos…'
        : added ? 'Already in To-dos' : 'Add to To-dos';
      for (const attribute of ['aria-label', 'title']) {
        if (button.getAttribute(attribute) !== label) button.setAttribute(attribute, label);
      }
      if (button.dataset.added !== String(added)) {
        button.dataset.added = String(added);
        button.innerHTML = dashboardIcons.render(added ? 'completed' : 'addTodo');
      }
      button.disabled = added || pending.has(thread.id) || writeProtected;
    });
  }

  function showNotice(message, failed) {
    notice?.remove();
    if (noticeTimer !== undefined) clearTimeout(noticeTimer);
    notice = document.createElement('div');
    notice.dataset.codexThreadTodoNotice = '';
    notice.setAttribute('role', failed ? 'alert' : 'status');
    notice.textContent = message;
    document.body.append(notice);
    noticeTimer = setTimeout(() => {
      notice?.remove();
      notice = undefined;
      noticeTimer = undefined;
    }, 4000);
  }

  async function addFromRow(row) {
    const thread = reference(row);
    if (!thread || pending.has(thread.id) || alreadyAdded(thread.id)) return;
    const projects = codexUIContracts.projects();
    const projectRow = row.closest('[data-app-action-sidebar-project-id]');
    const project = projects.find((candidate) => candidate.id === projectRow?.getAttribute('data-app-action-sidebar-project-id'))
      || projects.find((candidate) => candidate.path && candidate.path === thread.projectPath)
      || null;
    pending.add(thread.id);
    refresh();
    let saved = false;
    try { saved = await addTodo({ title: thread.title, thread, project }); }
    catch (_) {}
    pending.delete(thread.id);
    if (destroyed) return;
    refresh();
    showNotice(saved ? 'Added to To-dos' : 'Could not save this to-do. Try again.', !saved);
  }

  function handle(event) {
    const target = event.target instanceof Element ? event.target : null;
    const button = target?.closest('[data-codex-thread-todo]');
    if (!button) return;
    event.stopImmediatePropagation();
    if (event.type === 'keydown') {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        button.click();
      }
      return;
    }
    event.preventDefault();
    if (event.type === 'click' && !button.disabled) void addFromRow(button.closest(selector));
  }

  function mount() {
    if (destroyed) return;
    if (!started) {
      events.forEach((type) => document.addEventListener(type, handle, true));
      started = true;
    }
    const nextSidebar = codexHost.sidebar();
    if (sidebar !== nextSidebar) {
      observer?.disconnect();
      sidebar = nextSidebar;
      observer = new MutationObserver(refresh);
      if (sidebar) observer.observe(sidebar, { childList: true, subtree: true, characterData: true,
        attributes: true, attributeFilter: ['data-app-action-sidebar-thread-id', 'data-thread-title-trigger'] });
    }
    refresh();
  }

  function destroy() {
    destroyed = true;
    observer?.disconnect();
    events.forEach((type) => document.removeEventListener(type, handle, true));
    document.querySelectorAll('[data-codex-thread-todo]').forEach((button) => button.remove());
    if (noticeTimer !== undefined) clearTimeout(noticeTimer);
    notice?.remove();
  }

  return { mount, refresh, destroy };
}
