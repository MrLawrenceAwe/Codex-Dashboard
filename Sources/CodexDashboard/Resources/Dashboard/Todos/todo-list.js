const todoList = (() => {
  let items = todoListState.load();
  let filterMode = 'open';
  let pageIsOpen = false;

  function visibleItems() {
    if (filterMode === 'open') return items.filter((item) => !item.completed);
    if (filterMode === 'completed') return items.filter((item) => item.completed);
    return items;
  }

  function persist() {
    const saved = todoListState.save(items);
    const notice = document.querySelector('[data-todo-storage-error]');
    if (notice) notice.hidden = saved;
    return saved;
  }

  function updateNavigation() {
    const count = document.querySelector('[data-todo-navigation-count]');
    if (!count) return;
    const openCount = items.filter((item) => !item.completed).length;
    count.textContent = String(openCount);
    count.hidden = openCount === 0;
    count.setAttribute('aria-label', `${openCount} open ${openCount === 1 ? 'to-do' : 'to-dos'}`);
  }

  function render() {
    updateNavigation();
    const page = document.getElementById(dashboardElements.elementIDs.todoPage);
    if (!page) return;
    const openCount = items.filter((item) => !item.completed).length;
    const completedCount = items.length - openCount;
    page.querySelector('[data-todo-summary]').textContent = items.length
      ? `${openCount} open · ${completedCount} completed`
      : 'A little space for your next steps.';
    const progress = page.querySelector('[data-todo-progress]');
    progress.hidden = items.length === 0;
    progress.querySelector('progress').value = completedCount;
    progress.querySelector('progress').max = items.length || 1;
    progress.querySelector('span').textContent = `${completedCount} of ${items.length} done`;
    page.querySelectorAll('[data-todo-filter]').forEach((button) => {
      const active = button.dataset.todoFilter === filterMode;
      button.classList.toggle('is-active', active);
      button.setAttribute('aria-pressed', String(active));
      button.querySelector('[data-todo-filter-count]').textContent = String(
        button.dataset.todoFilter === 'open' ? openCount
          : button.dataset.todoFilter === 'completed' ? completedCount : items.length
      );
    });
    page.querySelector('[data-todo-clear-completed]').hidden = completedCount === 0;
    const list = page.querySelector('[data-todo-list]');
    const visible = visibleItems();
    if (!visible.length) {
      const message = !items.length ? 'Start with one small step'
        : filterMode === 'completed' ? 'Your wins will appear here' : 'All caught up';
      const detail = !items.length ? 'Add your first to-do above. Make room for what matters.'
        : filterMode === 'completed' ? 'Check off a to-do to see it here.' : 'Everything is checked off. Enjoy the breathing room.';
      list.innerHTML = `<div class="todo-empty"><span class="todo-empty-icon" aria-hidden="true">${threadMarkup.icon('completed')}</span><strong>${message}</strong><span>${detail}</span></div>`;
      return;
    }
    list.innerHTML = visible.map((item) => `
      <article class="todo-item${item.completed ? ' is-completed' : ''}" data-todo-id="${dashboardElements.escapeHTML(item.id)}">
        <label class="todo-check" title="${item.completed ? 'Mark as open' : 'Mark as completed'}">
          <input type="checkbox" data-todo-completed${item.completed ? ' checked' : ''} aria-label="${item.completed ? 'Mark as open' : 'Mark as completed'}: ${dashboardElements.escapeHTML(item.title)}">
          <span>${threadMarkup.icon('completed')}</span>
        </label>
        <div class="todo-item-copy">
          <input class="todo-title" data-todo-title value="${dashboardElements.escapeHTML(item.title)}" aria-label="To-do title" maxlength="240">
        </div>
        <button type="button" class="todo-delete" data-todo-delete aria-label="Delete ${dashboardElements.escapeHTML(item.title)}" title="Delete to-do">
          <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13M10 11v5m4-5v5"/></svg>
        </button>
      </article>
    `).join('');
  }

  function add(title) {
    const item = todoListState.create(title);
    if (!item) return false;
    items.unshift(item);
    persist();
    filterMode = 'open';
    render();
    return true;
  }

  function updateItem(id, changes) {
    const index = items.findIndex((item) => item.id === id);
    if (index < 0) return;
    items[index] = todoListState.normalizeItem({
      ...items[index],
      ...changes,
      updatedAt: Date.now(),
    }) || items[index];
    persist();
    render();
  }

  function mountNavigation() {
    if (document.getElementById(dashboardElements.elementIDs.todoNavButton)) return true;
    const taskButton = document.getElementById(dashboardElements.elementIDs.navButton);
    const insertionPoint = taskButton
      ? { element: taskButton, insertAfter: true }
      : codexHost.navigationInsertionPoint();
    if (!insertionPoint?.element?.parentElement) return false;
    const button = document.createElement('button');
    button.id = dashboardElements.elementIDs.todoNavButton;
    button.type = 'button';
    button.className = insertionPoint.element.className;
    button.setAttribute('aria-label', 'To-dos');
    button.innerHTML = `
      <span class="todo-nav-copy">
        <span class="todo-nav-icon">${threadMarkup.icon('completed')}</span>
        <span>To-dos</span>
      </span>
      <strong class="todo-nav-count" data-todo-navigation-count aria-label="0 open to-dos" hidden>0</strong>`;
    button.addEventListener('click', open);
    if (insertionPoint.insertAfter) insertionPoint.element.after(button);
    else insertionPoint.element.parentElement.insertBefore(button, insertionPoint.element);
    updateNavigation();
    if (pageIsOpen) button.setAttribute('aria-current', 'page');
    return true;
  }

  function mountPage() {
    if (document.getElementById(dashboardElements.elementIDs.todoPage)) return true;
    const pageHost = codexHost.pageHost();
    if (!pageHost) return false;
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.todoPage;
    page.setAttribute('aria-label', 'To-do list');
    page.innerHTML = `
      <div class="todo-shell">
        <header class="todo-header">
          <div><h1>To-dos</h1><p data-todo-summary role="status">A little space for your next steps.</p></div>
          <div class="todo-progress" data-todo-progress hidden><span></span><progress value="0" max="1" aria-label="To-do completion"></progress></div>
        </header>
        <form class="todo-add" data-todo-form>
          <input data-todo-new-title aria-label="New to-do" maxlength="240" placeholder="What needs to get done?" autocomplete="off">
          <button type="submit"><span aria-hidden="true">+</span> Add to-do</button>
        </form>
        <p class="todo-storage-error" data-todo-storage-error role="alert" hidden>Could not save this change. It may be lost when Codex reloads.</p>
        <div class="todo-toolbar">
          <div class="todo-filters" aria-label="Filter to-dos">
            <button type="button" data-todo-filter="open" class="is-active">Open<span class="todo-filter-count" data-todo-filter-count>0</span></button>
            <button type="button" data-todo-filter="all">All<span class="todo-filter-count" data-todo-filter-count>0</span></button>
            <button type="button" data-todo-filter="completed">Completed<span class="todo-filter-count" data-todo-filter-count>0</span></button>
          </div>
          <button type="button" class="todo-clear" data-todo-clear-completed hidden>Clear completed</button>
        </div>
        <main class="todo-list" data-todo-list></main>
        <p class="todo-hint">Click a title to edit it. Check it off when you’re done.</p>
      </div>`;
    page.querySelector('[data-todo-form]').addEventListener('submit', (event) => {
      event.preventDefault();
      const title = page.querySelector('[data-todo-new-title]');
      if (!add(title.value)) return;
      title.value = '';
      title.focus();
    });
    page.querySelectorAll('[data-todo-filter]').forEach((button) => {
      button.addEventListener('click', () => {
        filterMode = button.dataset.todoFilter;
        render();
      });
    });
    page.querySelector('[data-todo-clear-completed]').addEventListener('click', () => {
      items = items.filter((item) => !item.completed);
      persist();
      render();
    });
    page.querySelector('[data-todo-list]').addEventListener('change', (event) => {
      const row = event.target.closest('[data-todo-id]');
      if (!row) return;
      if (event.target.matches('[data-todo-completed]')) {
        updateItem(row.dataset.todoId, { completed: event.target.checked });
      } else if (event.target.matches('[data-todo-title]')) {
        const title = event.target.value.trim();
        if (title) updateItem(row.dataset.todoId, { title });
        else render();
      }
    });
    page.querySelector('[data-todo-list]').addEventListener('click', (event) => {
      const button = event.target.closest('[data-todo-delete]');
      if (!button) return;
      const row = button.closest('[data-todo-id]');
      if (!row) return;
      if (!button.dataset.todoDeleteConfirm) {
        button.dataset.todoDeleteConfirm = row.dataset.todoId;
        button.textContent = 'Confirm delete';
        button.setAttribute('aria-label', 'Confirm to-do deletion');
        button.title = 'Confirm delete to-do';
        return;
      }
      items = items.filter((item) => item.id !== row.dataset.todoId);
      persist();
      render();
    });
    pageHost.append(page);
    if (pageIsOpen) page.classList.add('is-open');
    render();
    return true;
  }

  function open() {
    taskDashboard.close();
    if (!document.getElementById(dashboardElements.elementIDs.todoPage)) mountPage();
    const page = document.getElementById(dashboardElements.elementIDs.todoPage);
    if (!page) return;
    pageIsOpen = true;
    page.classList.add('is-open');
    document.documentElement.classList.add('codex-todo-open');
    document.getElementById(dashboardElements.elementIDs.todoNavButton)?.setAttribute('aria-current', 'page');
    render();
  }

  function close() {
    pageIsOpen = false;
    document.getElementById(dashboardElements.elementIDs.todoPage)?.classList.remove('is-open');
    document.documentElement.classList.remove('codex-todo-open');
    document.getElementById(dashboardElements.elementIDs.todoNavButton)?.removeAttribute('aria-current');
  }

  function restoreOpenState() {
    if (!pageIsOpen) return;
    document.getElementById(dashboardElements.elementIDs.todoPage)?.classList.add('is-open');
    document.documentElement.classList.add('codex-todo-open');
    document.getElementById(dashboardElements.elementIDs.todoNavButton)?.setAttribute('aria-current', 'page');
  }

  function destroy() {
    pageIsOpen = false;
    document.documentElement.classList.remove('codex-todo-open');
  }

  return {
    close,
    destroy,
    isOpen: () => pageIsOpen,
    mountNavigation,
    mountPage,
    open,
    restoreOpenState,
  };
})();
