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

  function tagMarkup(tags, editable = false, deletable = false) {
    if (!tags.length) return '';
    return `<div class="todo-tags" aria-label="To-do tags">${tags.map((tag) => `
      <span class="todo-tag">${domUtils.escapeHTML(tag)}${editable ? `<button type="button" data-todo-tag-remove="${domUtils.escapeHTML(tag)}" aria-label="Remove tag ${domUtils.escapeHTML(tag)}" title="Remove tag ${domUtils.escapeHTML(tag)}">&times;</button>` : ''}${deletable ? `<button type="button" data-todo-managed-tag-edit="${domUtils.escapeHTML(tag)}" aria-label="Rename tag ${domUtils.escapeHTML(tag)}" title="Rename tag">&#9998;</button><button type="button" data-todo-managed-tag-remove="${domUtils.escapeHTML(tag)}" aria-label="Delete tag ${domUtils.escapeHTML(tag)} from all to-dos" title="Delete tag from all to-dos">&times;</button>` : ''}</span>
    `).join('')}</div>`;
  }

  function projectPickerMarkup(project) {
    return `<select class="todo-project-picker" data-todo-project aria-label="Project for this to-do">${projectOptions(codexUIContracts.projects(), project?.id)}</select>`;
  }

  function tagOptions(tags, selectedTag = '') {
    return `<option value="">Choose a tag</option>${tags.map((tag) => (
      `<option value="${domUtils.escapeHTML(tag)}"${tag === selectedTag ? ' selected' : ''}>${domUtils.escapeHTML(tag)}</option>`
    )).join('')}`;
  }

  function tagPickerMarkup(tags) {
    return `<div class="todo-tag-picker">
      <select data-todo-tag aria-label="Tag to attach">${tagOptions(tags)}</select>
    </div>`;
  }

  function projectOptions(projects, selectedID = '') {
    return `<option value="">No project</option>${projects.map((project) => (
      `<option value="${domUtils.escapeHTML(project.id)}"${project.id === selectedID ? ' selected' : ''}>${domUtils.escapeHTML(project.name)}</option>`
    )).join('')}`;
  }

  function filterProjectOptions(projects, items, selectedID = '') {
    const projectCounts = new Map();
    items.forEach((item) => {
      const projectID = item.project?.id || '__none__';
      projectCounts.set(projectID, (projectCounts.get(projectID) || 0) + 1);
    });
    const noProjectCount = projectCounts.get('__none__') || 0;
    return `<option value="">All projects</option><option value="__none__"${selectedID === '__none__' ? ' selected' : ''}>No project (${noProjectCount})</option>${projects.map((project) => (
      `<option value="${domUtils.escapeHTML(project.id)}"${project.id === selectedID ? ' selected' : ''}>${domUtils.escapeHTML(project.name)} (${projectCounts.get(project.id) || 0})</option>`
    )).join('')}`;
  }

  function filterTagOptions(tags, items, selectedTag = '') {
    const tagCounts = new Map();
    items.forEach((item) => item.tags.forEach((tag) => {
      tagCounts.set(tag, (tagCounts.get(tag) || 0) + 1);
    }));
    return `<option value="">All tags</option>${tags.map((tag) => (
      `<option value="${domUtils.escapeHTML(tag)}"${tag === selectedTag ? ' selected' : ''}>${domUtils.escapeHTML(tag)} (${tagCounts.get(tag) || 0})</option>`
    )).join('')}`;
  }

  function visibleItems(items, filterMode, projectFilter, tagFilter) {
    return items.filter((item) => {
      const matchesStatus = filterMode === 'all'
        || (filterMode === 'open' && !item.completed)
        || (filterMode === 'completed' && item.completed);
      const matchesProject = !projectFilter
        || (projectFilter === '__none__' && !item.project)
        || item.project?.id === projectFilter;
      const matchesTag = !tagFilter || item.tags.includes(tagFilter);
      return matchesStatus && matchesProject && matchesTag;
    });
  }

  function updateNavigation(openCount) {
    const count = document.querySelector('[data-todo-navigation-count]');
    if (!count) return;
    count.textContent = String(openCount);
    count.hidden = openCount === 0;
    count.setAttribute('aria-label', `${openCount} open ${openCount === 1 ? 'to-do' : 'to-dos'}`);
  }

  function sizeTitle(title) {
    title.style.height = 'auto';
    title.style.height = `${Math.min(title.scrollHeight, 144)}px`;
  }

  function render(items, filterMode, availableTags = [], projects = [], filters = {}) {
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
    const projectFilter = page.querySelector('[data-todo-project-filter]');
    const tagFilter = page.querySelector('[data-todo-tag-filter]');
    if (projectFilter) projectFilter.innerHTML = filterProjectOptions(projects, items, filters.project || '');
    if (tagFilter) tagFilter.innerHTML = filterTagOptions(availableTags, items, filters.tag || '');
    const list = page.querySelector('[data-todo-list]');
    const visible = visibleItems(items, filterMode, filters.project, filters.tag);
    if (!visible.length) {
      const message = !items.length ? 'No to-dos yet'
        : filters.project || filters.tag ? 'No matching to-dos'
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
          <textarea class="todo-title" data-todo-title aria-label="To-do title" maxlength="240" rows="1">${domUtils.escapeHTML(item.title)}</textarea>
          <textarea class="todo-body" data-todo-body aria-label="To-do details" maxlength="5000" placeholder="Add details…">${domUtils.escapeHTML(item.body)}</textarea>
          ${projectPickerMarkup(item.project)}
          ${tagMarkup(item.tags, !item.completed)}
          ${!item.completed ? tagPickerMarkup(availableTags) : ''}
          ${imageMarkup(item)}
          ${!item.completed && item.image ? `<div class="todo-image-actions">
            <button type="button" data-todo-image-remove>Remove image</button>
          </div>` : ''}
        </div>
        ${!item.completed && item.project ? `<button type="button" class="todo-new-chat" data-todo-new-chat aria-label="Start a new chat for ${domUtils.escapeHTML(item.project.name)}" title="Start a new chat">New chat</button>` : ''}
        <button type="button" class="todo-delete" data-todo-delete aria-label="Delete ${domUtils.escapeHTML(item.title)}" title="Delete to-do">
          <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13M10 11v5m4-5v5"/></svg>
        </button>
      </article>
    `).join('');
    list.querySelectorAll('[data-todo-title]').forEach(sizeTitle);
  }

  function createPage() {
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.todoPage;
    page.setAttribute('aria-label', 'To-do list');
    page.innerHTML = `
      <div class="todo-shell">
        <header class="todo-header">
          <h1>To-dos</h1>
          <button type="button" class="todo-manage-tags" data-todo-manage-tags>Tags</button>
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
            <div class="todo-tag-composer">
              <select data-todo-new-project aria-label="Project">${projectOptions([])}</select>
              <div class="todo-tags" data-todo-new-tags aria-label="New to-do tags"></div>
              <select data-todo-new-tag aria-label="Tag to attach">${tagOptions([])}</select>
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
          <div class="todo-attribute-filters" aria-label="Filter to-dos by project or tag">
            <select data-todo-project-filter aria-label="Filter by project"><option value="">All projects</option></select>
            <select data-todo-tag-filter aria-label="Filter by tag"><option value="">All tags</option></select>
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
    const dialogHost = document.createElement('div');
    dialogHost.id = 'codex-dashboard-todo-dialogs';
    dialogHost.innerHTML = `
      <dialog class="todo-image-dialog" data-todo-image-dialog aria-label="Image preview">
        <button type="button" data-todo-image-dialog-close aria-label="Close image preview">&times;</button>
        <img alt="">
      </dialog>
      <dialog class="todo-tag-dialog" data-todo-tag-dialog aria-label="Manage tags">
        <header class="todo-tag-dialog-header"><strong>Tags</strong><button type="button" data-todo-tag-dialog-close aria-label="Close tags">&times;</button></header>
        <form data-todo-tag-form class="todo-tag-form">
          <input data-todo-tag-name aria-label="Tag name" placeholder="New tag name" autocomplete="off">
          <button type="submit">Create tag</button>
        </form>
        <div class="todo-tags" data-todo-managed-tags aria-label="Available tags"></div>
      </dialog>`;
    document.body.append(dialogHost);
    const imageDialog = dialogHost.querySelector('[data-todo-image-dialog]');
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

  function updateTagDraft(tags) {
    const container = document.querySelector('[data-todo-new-tags]');
    if (!container) return;
    container.innerHTML = tagMarkup(tags, true);
  }

  function updateTagOptions(tags) {
    document.querySelectorAll('[data-todo-new-tag], [data-todo-tag]').forEach((select) => {
      select.innerHTML = tagOptions(tags, select.value);
    });
  }

  function updateProjectOptions(projects, selectedID = '') {
    document.querySelectorAll('[data-todo-new-project], [data-todo-project]').forEach((select) => {
      const itemID = select.closest('[data-todo-id]')?.dataset.todoId;
      const selectedProjectID = itemID
        ? select.value
        : selectedID || select.value;
      select.innerHTML = projectOptions(projects, selectedProjectID);
    });
  }

  function updateFilterOptions(projects, tags, items, filters = {}) {
    const projectFilter = document.querySelector('[data-todo-project-filter]');
    const tagFilter = document.querySelector('[data-todo-tag-filter]');
    if (projectFilter) projectFilter.innerHTML = filterProjectOptions(projects, items, filters.project || '');
    if (tagFilter) tagFilter.innerHTML = filterTagOptions(tags, items, filters.tag || '');
  }

  function updateManagedTags(tags) {
    const container = document.querySelector('[data-todo-managed-tags]');
    if (container) container.innerHTML = tagMarkup(tags, false, true);
  }

  function showImage(image) {
    const dialog = document.querySelector('[data-todo-image-dialog]');
    if (!dialog) return;
    const preview = dialog.querySelector('img');
    preview.src = image.dataURL;
    preview.alt = image.name;
    dialog.showModal();
  }

  return { createPage, render, showImage, sizeTitle, updateTagDraft, updateTagOptions, updateImageDraft, updateManagedTags, updateNavigation, updateProjectOptions, updateFilterOptions };
})();
