const todoListView = (() => {
  function imageMarkup(item) {
    if (!item.image) return '';
    const name = domUtils.escapeHTML(item.image.name);
    return `
      <div class="todo-image">
        <button type="button" class="todo-image-preview" data-todo-image-preview aria-label="View image: ${name}" title="View image">
          <img src="${domUtils.escapeHTML(item.image.dataURL)}" alt="${name}">
        </button>
        <span class="todo-image-name" title="${name}">${name}</span>
      </div>`;
  }

  function visibleItems(items, filterMode) {
    if (filterMode === 'open') return items.filter((item) => !item.completed);
    if (filterMode === 'completed') return items.filter((item) => item.completed);
    return items;
  }

  function updateNavigation(openCount) {
    const count = document.querySelector('[data-todo-navigation-count]');
    if (!count) return;
    count.textContent = String(openCount);
    count.hidden = openCount === 0;
    count.setAttribute('aria-label', `${openCount} open ${openCount === 1 ? 'to-do' : 'to-dos'}`);
  }

  function render(items, filterMode) {
    const openCount = items.filter((item) => !item.completed).length;
    updateNavigation(openCount);
    const page = document.getElementById(dashboardElements.elementIDs.todoPage);
    if (!page) return;
    const completedCount = items.length - openCount;
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
    const visible = visibleItems(items, filterMode);
    if (!visible.length) {
      const message = !items.length ? 'No to-dos yet'
        : filterMode === 'completed' ? 'No completed to-dos' : 'All caught up';
      list.innerHTML = `<div class="todo-empty"><span class="todo-empty-icon" aria-hidden="true">${threadMarkup.icon('completed')}</span><strong>${message}</strong></div>`;
      return;
    }
    list.innerHTML = visible.map((item) => `
      <article class="todo-item${item.completed ? ' is-completed' : ''}" data-todo-id="${domUtils.escapeHTML(item.id)}">
        <label class="todo-check" title="${item.completed ? 'Mark as open' : 'Mark as completed'}">
          <input type="checkbox" data-todo-completed${item.completed ? ' checked' : ''} aria-label="${item.completed ? 'Mark as open' : 'Mark as completed'}: ${domUtils.escapeHTML(item.title)}">
          <span>${threadMarkup.icon('completed')}</span>
        </label>
        <div class="todo-item-copy">
          <input class="todo-title" data-todo-title value="${domUtils.escapeHTML(item.title)}" aria-label="To-do title" maxlength="240">
          ${imageMarkup(item)}
          ${item.completed ? '' : `<div class="todo-image-actions">
            <span class="todo-image-paste-hint">Paste an image into the title to ${item.image ? 'replace' : 'attach'} it.</span>
            ${item.image ? '<button type="button" data-todo-image-remove>Remove image</button>' : ''}
          </div>`}
        </div>
        <button type="button" class="todo-delete" data-todo-delete aria-label="Delete ${domUtils.escapeHTML(item.title)}" title="Delete to-do">
          <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13M10 11v5m4-5v5"/></svg>
        </button>
      </article>
    `).join('');
  }

  function createPage() {
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.todoPage;
    page.setAttribute('aria-label', 'To-do list');
    page.innerHTML = `
      <div class="todo-shell">
        <header class="todo-header">
          <h1>To-dos</h1>
        </header>
        <form class="todo-add" data-todo-form>
          <input data-todo-new-title aria-label="New to-do" maxlength="240" placeholder="Add a to-do… Paste an image to attach it" autocomplete="off">
          <button type="submit"><span aria-hidden="true">+</span> Add</button>
        </form>
        <p class="todo-image-paste-status" data-todo-new-image-status hidden></p>
        <p class="todo-storage-error" data-todo-storage-error role="alert" hidden>Could not save this change. It may be lost when Codex reloads.</p>
        <p class="todo-storage-error" data-todo-image-error role="alert" hidden></p>
        <div class="todo-toolbar">
          <div class="todo-filters" aria-label="Filter to-dos">
            <button type="button" data-todo-filter="open" class="is-active">Open<span class="todo-filter-count" data-todo-filter-count>0</span></button>
            <button type="button" data-todo-filter="all">All<span class="todo-filter-count" data-todo-filter-count>0</span></button>
            <button type="button" data-todo-filter="completed">Completed<span class="todo-filter-count" data-todo-filter-count>0</span></button>
          </div>
          <button type="button" class="todo-clear" data-todo-clear-completed hidden>Clear completed</button>
        </div>
        <main class="todo-list" data-todo-list></main>
      </div>`;
    page.insertAdjacentHTML('beforeend', `
      <dialog class="todo-image-dialog" data-todo-image-dialog aria-label="Image preview">
        <button type="button" data-todo-image-dialog-close aria-label="Close image preview">&times;</button>
        <img alt="">
      </dialog>`);
    const imageDialog = page.querySelector('[data-todo-image-dialog]');
    imageDialog.querySelector('[data-todo-image-dialog-close]').addEventListener('click', () => imageDialog.close());
    imageDialog.addEventListener('click', (event) => {
      if (event.target === imageDialog) imageDialog.close();
    });
    return page;
  }

  function showImage(image) {
    const dialog = document.querySelector('[data-todo-image-dialog]');
    if (!dialog) return;
    const preview = dialog.querySelector('img');
    preview.src = image.dataURL;
    preview.alt = image.name;
    dialog.showModal();
  }

  return { createPage, render, showImage, updateNavigation };
})();
