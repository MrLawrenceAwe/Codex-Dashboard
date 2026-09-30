function createSidebarThreadTodoActions({ findThread, getItems, addTodo }) {
  const selector = '[data-app-action-sidebar-thread-id]';
  const events = ['contextmenu', 'pointerdown', 'mousedown', 'click', 'keydown'];
  let menuContext;
  let observedBody;
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
        || !node.matches('button, svg'))
        .map((node) => node.textContent).join('')).trim();
    return id && title ? { id, title, projectPath: thread?.projectPath } : null;
  }

  function alreadyAdded(id) {
    return getItems().some((item) => !item.completed && item.thread?.id === id);
  }

  function refresh() {
    if (!menuContext || destroyed) return;
    if (menuContext.menu && (!menuContext.menu.isConnected || !domUtils.isVisible(menuContext.menu))) {
      menuContext = null;
      return;
    }
    const menu = menuContext.menu || [...document.querySelectorAll('[role="menu"]')]
      .find((candidate) => !menuContext.previousMenus.has(candidate) && domUtils.isVisible(candidate));
    if (!menu || (!menuContext.menu && Date.now() > menuContext.expiresAt)) return;
    menuContext.menu = menu;
    let button = menu.querySelector('[data-codex-thread-todo-menu-item]');
    if (!button) {
      button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('role', 'menuitem');
      button.dataset.codexThreadTodoMenuItem = '';
      button.innerHTML = `${dashboardIcons.render('addTodo')}<span></span>`;
      menu.append(button);
    }
    const id = menuContext.draft.thread.id;
    const added = alreadyAdded(id);
    const label = pending.has(id) ? 'Adding to To-dos…'
      : added ? 'Already in To-dos' : 'Add to To-dos';
    if (button.textContent !== label) button.querySelector('span').textContent = label;
    const disabled = added || pending.has(id) || Boolean(todoStore.writeProtectionReason());
    button.disabled = disabled;
    if (button.getAttribute('aria-disabled') !== String(disabled)) {
      button.setAttribute('aria-disabled', String(disabled));
    }
  }

  function prepareMenu(row) {
    document.querySelectorAll('[data-codex-thread-todo-menu-item]').forEach((item) => item.remove());
    const thread = reference(row);
    if (!thread) { menuContext = null; return; }
    const projects = codexUIContracts.projects();
    const projectRow = row.closest('[data-app-action-sidebar-project-id]');
    const project = projects.find((candidate) => candidate.id === projectRow?.getAttribute('data-app-action-sidebar-project-id'))
      || projects.find((candidate) => candidate.path && candidate.path === thread.projectPath)
      || null;
    menuContext = {
      draft: { title: thread.title, thread, project },
      previousMenus: new Set([...document.querySelectorAll('[role="menu"]')].filter(domUtils.isVisible)),
      expiresAt: Date.now() + 1500,
      menu: null,
    };
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

  async function addFromMenu(context) {
    const { thread } = context.draft;
    if (pending.has(thread.id) || alreadyAdded(thread.id)) return;
    pending.add(thread.id);
    refresh();
    // Ask the host menu to close through its normal Escape handler.
    context.menu.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Escape', bubbles: true, cancelable: true,
    }));
    let saved = false;
    try { saved = await addTodo(context.draft); }
    catch (_) {}
    pending.delete(thread.id);
    if (destroyed) return;
    refresh();
    showNotice(saved ? 'Added to To-dos' : 'Could not save this to-do. Try again.', !saved);
  }

  function handle(event) {
    const target = event.target instanceof Element ? event.target : null;
    const row = target?.closest(selector);
    if (event.type === 'contextmenu') {
      if (row && codexHost.sidebar()?.contains(row)) prepareMenu(row);
      else menuContext = null;
      return;
    }
    if (row && codexHost.sidebar()?.contains(row)
      && ((event.type === 'click' && target.closest('[aria-haspopup="menu"]'))
        || (event.type === 'keydown' && (event.key === 'ContextMenu'
          || (event.shiftKey && event.key === 'F10'))))) {
      prepareMenu(row);
      return;
    }
    const button = target?.closest('[data-codex-thread-todo-menu-item]');
    const menu = menuContext?.menu;
    if (event.type === 'pointerdown' && !button && !menu?.contains(target)) {
      menuContext = null;
    }
    // Include the injected item in keyboard navigation, since the host menu's
    // React collection only knows about its own items.
    if (event.type === 'keydown' && menu?.contains(target)
      && ['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      const items = [...menu.querySelectorAll('[role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"]')]
        .filter((item) => !item.disabled && item.getAttribute('aria-disabled') !== 'true' && domUtils.isVisible(item));
      if (!items.length) return;
      const current = items.indexOf(document.activeElement);
      const index = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1
        : (current + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      event.preventDefault();
      event.stopImmediatePropagation();
      items[index].focus();
      return;
    }
    if (!button) return;
    if (event.type === 'keydown' && !['Enter', ' '].includes(event.key)) return;
    event.stopImmediatePropagation();
    event.preventDefault();
    if (event.type === 'keydown') button.click();
    if (event.type === 'click' && !button.disabled && menuContext) void addFromMenu(menuContext);
  }

  function mount() {
    if (destroyed) return;
    if (!started) {
      events.forEach((type) => document.addEventListener(type, handle, true));
      started = true;
    }
    if (observedBody !== document.body) {
      observer?.disconnect();
      observedBody = document.body;
      observer = new MutationObserver(refresh);
      if (observedBody) observer.observe(observedBody, { childList: true, subtree: true,
        attributes: true, attributeFilter: ['role', 'data-state', 'hidden'] });
    }
    refresh();
  }

  function destroy() {
    destroyed = true;
    observer?.disconnect();
    events.forEach((type) => document.removeEventListener(type, handle, true));
    document.querySelectorAll('[data-codex-thread-todo-menu-item]').forEach((button) => button.remove());
    menuContext = null;
    if (noticeTimer !== undefined) clearTimeout(noticeTimer);
    notice?.remove();
  }

  return { mount, refresh, destroy };
}
