const todoListView = (() => {
  function imageMarkup(item) {
    if (!item.image?.dataURL) return '';
    const name = domUtils.escapeHTML(item.image.name);
    return `
      <div class="todo-image">
        <button type="button" class="todo-image-preview" data-todo-image-preview aria-label="View image: ${name}" title="View image">
          <img src="${domUtils.escapeHTML(item.image.dataURL)}" alt="${name}">
        </button>
        <span class="todo-image-name" title="${name}">${name}</span>
      </div>`;
  }

  function badgeMarkup(badges, editable = false) {
    if (!badges.length) return '';
    return `<div class="todo-badges" aria-label="To-do badges">${badges.map((badge) => `
      <span class="todo-badge">${domUtils.escapeHTML(badge)}${editable ? `<button type="button" data-todo-badge-remove="${domUtils.escapeHTML(badge)}" aria-label="Remove badge ${domUtils.escapeHTML(badge)}" title="Remove badge ${domUtils.escapeHTML(badge)}">&times;</button>` : ''}</span>
    `).join('')}</div>`;
  }

  function badgeOptions(badges, selectedBadge = '') {
    return `<option value="">Choose a badge</option>${badges.map((badge) => (
      `<option value="${domUtils.escapeHTML(badge)}"${badge === selectedBadge ? ' selected' : ''}>${domUtils.escapeHTML(badge)}</option>`
    )).join('')}`;
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
      list.innerHTML = `<div class="todo-empty"><span class="todo-empty-icon" aria-hidden="true">${dashboardIcons.render('completed')}</span><strong>${message}</strong></div>`;
      return;
    }
    list.innerHTML = visible.map((item) => `
      <article class="todo-item${item.completed ? ' is-completed' : ''}" data-todo-id="${domUtils.escapeHTML(item.id)}">
        <label class="todo-check" title="${item.completed ? 'Mark as open' : 'Mark as completed'}">
          <input type="checkbox" data-todo-completed${item.completed ? ' checked' : ''} aria-label="${item.completed ? 'Mark as open' : 'Mark as completed'}: ${domUtils.escapeHTML(item.title)}">
          <span>${dashboardIcons.render('completed')}</span>
        </label>
        <div class="todo-item-copy">
          <input class="todo-title" data-todo-title value="${domUtils.escapeHTML(item.title)}" aria-label="To-do title" maxlength="240">
          <textarea class="todo-body" data-todo-body aria-label="To-do details" maxlength="5000" placeholder="Add details…">${domUtils.escapeHTML(item.body)}</textarea>
          ${badgeMarkup(item.badges, !item.completed)}
          ${imageMarkup(item)}
          ${!item.completed && item.image ? `<div class="todo-image-actions">
            <button type="button" data-todo-image-remove>Remove image</button>
          </div>` : ''}
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
          <button type="button" class="todo-manage-badges" data-todo-manage-badges>Badges</button>
        </header>
        <form class="todo-add" data-todo-form>
          <div class="todo-add-image" data-todo-new-image-preview hidden>
            <button type="button" class="todo-add-image-preview" data-todo-new-image-open aria-label="Preview pasted image" title="Preview pasted image">
              <img alt="">
            </button>
            <button type="button" data-todo-new-image-remove aria-label="Remove pasted image" title="Remove pasted image">&times;</button>
          </div>
          <div class="todo-add-fields">
            <input data-todo-new-title aria-label="New to-do" maxlength="240" placeholder="Add a to-do" autocomplete="off">
            <textarea data-todo-new-body aria-label="New to-do details" maxlength="5000" placeholder="Add details (optional)" rows="1"></textarea>
            <div class="todo-badge-composer">
              <div class="todo-badges" data-todo-new-badges aria-label="New to-do badges"></div>
              <select data-todo-new-badge aria-label="Badge to attach">${badgeOptions([])}</select>
              <button type="button" data-todo-new-badge-add>Attach badge</button>
            </div>
          </div>
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
    const addForm = page.querySelector('[data-todo-form]');
    const titleInput = page.querySelector('[data-todo-new-title]');
    const addButton = addForm.querySelector('button[type="submit"]');
    // Codex applies high-priority form-control styles to its own renderer. Keep
    // this small composer self-contained even when those styles change.
    addForm.style.setProperty('display', 'grid', 'important');
    addForm.style.setProperty('grid-template-columns', 'minmax(0, 1fr) auto', 'important');
    addForm.style.setProperty('width', '100%', 'important');
    addForm.style.setProperty('padding', '0', 'important');
    titleInput.style.setProperty('width', '100%', 'important');
    titleInput.style.setProperty('max-width', 'none', 'important');
    titleInput.style.setProperty('min-width', '0', 'important');
    addButton.style.setProperty('width', 'auto', 'important');
    page.insertAdjacentHTML('beforeend', `
      <dialog class="todo-image-dialog" data-todo-image-dialog aria-label="Image preview">
        <button type="button" data-todo-image-dialog-close aria-label="Close image preview">&times;</button>
        <img alt="">
      </dialog>
      <dialog class="todo-badge-dialog" data-todo-badge-dialog aria-label="Manage badges">
        <header class="todo-badge-dialog-header"><strong>Badges</strong><button type="button" data-todo-badge-dialog-close aria-label="Close badges">&times;</button></header>
        <form data-todo-badge-form class="todo-badge-form">
          <input data-todo-badge-name aria-label="Badge name" maxlength="40" placeholder="New badge name" autocomplete="off">
          <button type="submit">Create badge</button>
        </form>
        <div class="todo-badges" data-todo-managed-badges aria-label="Available badges"></div>
      </dialog>`);
    const imageDialog = page.querySelector('[data-todo-image-dialog]');
    imageDialog.querySelector('[data-todo-image-dialog-close]').addEventListener('click', () => imageDialog.close());
    imageDialog.addEventListener('click', (event) => {
      if (event.target === imageDialog) imageDialog.close();
    });
    return page;
  }

  function updateImageDraft(image) {
    const preview = document.querySelector('[data-todo-new-image-preview]');
    if (!preview) return;
    const previewImage = preview.querySelector('img');
    const form = preview.closest('[data-todo-form]');
    preview.hidden = !image;
    previewImage.src = image?.dataURL || '';
    previewImage.alt = image?.name || '';
    preview.title = image?.name || '';
    const previewButton = preview.querySelector('[data-todo-new-image-open]');
    previewButton?.setAttribute('aria-label', image ? `Preview pasted image: ${image.name}` : 'Preview pasted image');
    previewButton?.setAttribute('title', image ? `Preview ${image.name}` : 'Preview pasted image');
    form?.style.setProperty(
      'grid-template-columns',
      image ? 'auto minmax(0, 1fr) auto' : 'minmax(0, 1fr) auto',
      'important'
    );
  }

  function updateBadgeDraft(badges) {
    const container = document.querySelector('[data-todo-new-badges]');
    if (!container) return;
    container.innerHTML = badgeMarkup(badges, true);
  }

  function updateBadgeOptions(badges) {
    const select = document.querySelector('[data-todo-new-badge]');
    if (!select) return;
    select.innerHTML = badgeOptions(badges, select.value);
  }

  function updateManagedBadges(badges) {
    const container = document.querySelector('[data-todo-managed-badges]');
    if (container) container.innerHTML = badgeMarkup(badges);
  }

  function showImage(image) {
    const dialog = document.querySelector('[data-todo-image-dialog]');
    if (!dialog) return;
    const preview = dialog.querySelector('img');
    preview.src = image.dataURL;
    preview.alt = image.name;
    dialog.showModal();
  }

  return { createPage, render, showImage, updateBadgeDraft, updateBadgeOptions, updateImageDraft, updateManagedBadges, updateNavigation };
})();
