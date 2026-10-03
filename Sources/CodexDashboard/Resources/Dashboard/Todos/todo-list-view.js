const todoListView = (() => {
  function projectPickerMarkup(project, projects) {
    return `<select class="todo-project-picker" data-todo-project aria-label="Project for this to-do">${projectOptions(projects, project?.id, project)}</select>`;
  }

  function threadMarkup(thread) {
    if (!thread) return '';
    const title = domUtils.escapeHTML(thread.title);
    return `<div class="todo-thread" aria-label="Linked chat: ${title}" title="Linked chat: ${title}">
      <span aria-hidden="true">#</span><span>${title}</span>
    </div>`;
  }

  function presetFields(preset, scope) {
    return `<div class="todo-preset-fields" data-todo-${scope}-preset-fields${preset ? '' : ' hidden'}>
      ${composerPresets.fieldsMarkup(preset, {
        model: `data-todo-${scope}-preset-model`,
        reasoningEffort: `data-todo-${scope}-preset-effort`,
        speed: `data-todo-${scope}-preset-speed`,
      })}
    </div>`;
  }

  function itemPresetMarkup(item) {
    return `<details class="todo-preset" data-todo-preset-details>
      <summary>${domUtils.escapeHTML((composerPresets.summary(item.preset).join(' · ') || 'Model settings'))}</summary>
      <label class="todo-preset-toggle"><input type="checkbox" data-todo-preset-enabled${item.preset ? ' checked' : ''}>Apply model settings</label>
      ${presetFields(item.preset, 'item')}
    </details>`;
  }

  function projectOptions(projects, selectedID = '', savedProject = null) {
    const unavailable = savedProject && !projects.some((project) => project.id === savedProject.id)
      ? `<option value="${domUtils.escapeHTML(savedProject.id)}" selected disabled>Unavailable · ${domUtils.escapeHTML(savedProject.name)}</option>` : '';
    return `<option value="">No project</option>${unavailable}${projects.map((project) => (
      `<option value="${domUtils.escapeHTML(project.id)}"${project.id === selectedID ? ' selected' : ''}>${domUtils.escapeHTML(project.name)}</option>`
    )).join('')}`;
  }

  function threadOptions(threads, selectedID = '') {
    if (!threads.length) return '<option value="">No chats in this project</option>';
    return `<option value="">No linked chat</option>${threads.map((thread) => (
      `<option value="${domUtils.escapeHTML(thread.id)}"${thread.id === selectedID ? ' selected' : ''}>${domUtils.escapeHTML(thread.title)}</option>`
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

  function render({ items, filterMode, availableTags, projects, filterProjects, filters }) {
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
    updateFilterOptions(filterProjects, availableTags, items, filters);
    const list = page.querySelector('[data-todo-list]');
    const visible = todoQuery.visibleItems(items, filterMode, filters.project, filters.tag);
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
          ${projectPickerMarkup(item.project, projects)}
          ${threadMarkup(item.thread)}
          ${itemPresetMarkup(item)}
          ${todoTagView.tagMarkup(item.tags, !item.completed)}
          ${!item.completed ? todoTagView.tagPickerMarkup(availableTags) : ''}
          ${todoImageView.imageMarkup(item)}
          ${!item.completed && item.image ? `<div class="todo-image-actions">
            <button type="button" data-todo-image-remove>Remove image</button>
          </div>` : ''}
          ${!item.completed ? `<div class="todo-item-actions">
            <button type="button" class="todo-thread-action" data-todo-paste-in-thread aria-expanded="false" aria-label="Choose a chat to paste this to-do into" title="${item.project ? 'Choose a chat from this project' : 'Assign a project to choose a chat'}"${item.project ? '' : ' disabled'}>Paste into chat…</button>
            ${!item.thread && item.project ? `<button type="button" class="todo-thread-action" data-todo-new-thread aria-label="Start a new chat for ${domUtils.escapeHTML(item.project.name)}" title="Start a new chat">New chat</button>` : ''}
            <select class="todo-paste-thread-picker" data-todo-paste-thread aria-label="Chat to paste this to-do into" hidden disabled></select>
          </div>` : ''}
        </div>
        <button type="button" class="todo-delete" data-todo-delete aria-label="Delete ${domUtils.escapeHTML(item.title)}" title="Delete to-do">
          <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13M10 11v5m4-5v5"/></svg>
        </button>
      </article>
    `).join('');
    list.querySelectorAll('[data-todo-title]').forEach(sizeTitle);
  }

  function createPage() {
    document.getElementById(dashboardElements.elementIDs.todoDialogHost)?.remove();
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
              <select data-todo-new-thread-picker aria-label="Linked chat" title="Choose a chat from the selected project" hidden disabled><option value="">No chats in this project</option></select>
              <div class="todo-tags" data-todo-new-tags aria-label="New to-do tags"></div>
              <select data-todo-new-tag aria-label="Tag to attach">${todoTagView.tagOptions([])}</select>
            </div>
            <div class="todo-new-preset">
              <label class="todo-preset-toggle"><input type="checkbox" data-todo-new-preset-enabled>Apply model settings</label>
              ${presetFields(null, 'new')}
            </div>
          </div>
          <button type="submit"><span aria-hidden="true">+</span> Add</button>
        </form>
        <p class="todo-image-paste-status" data-todo-new-image-status hidden></p>
        <p class="todo-storage-error" data-todo-storage-error role="alert" hidden>Could not save this change. It may be lost when Codex reloads.</p>
        <p class="todo-storage-error" data-todo-composer-error role="alert" hidden>Could not apply this to-do’s model settings. The to-do was not inserted.</p>
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
          <button type="button" class="todo-clear" data-todo-clear-completed hidden>Delete all completed to-dos</button>
        </div>
        <main class="todo-list" data-todo-list></main>
      </div>`;
    todoDialogHost.ensure();
    return page;
  }

  function updateTopInset(page) {
    let zoom = 1;
    for (let ancestor = page.parentElement; ancestor; ancestor = ancestor.parentElement) {
      const value = Number.parseFloat(getComputedStyle(ancestor).zoom);
      if (Number.isFinite(value) && value > 0) zoom *= value;
    }
    page.style.setProperty('--todo-top-inset', `${56 / zoom}px`);
  }

  function updateNewProjectOptions(projects, selectedID = '') {
    const select = document.querySelector('[data-todo-new-project]');
    if (select) select.innerHTML = projectOptions(projects, selectedID);
  }

  function updateItemProjectOptions(projects, items) {
    const projectsByItemID = new Map(items.map((item) => [item.id, item.project]));
    document.querySelectorAll('[data-todo-project]').forEach((select) => {
      const project = projectsByItemID.get(select.closest('[data-todo-id]').dataset.todoId);
      select.innerHTML = projectOptions(projects, project?.id, project);
    });
  }

  function updateThreadOptions(threads, hasProject, selectedID = '') {
    const select = document.querySelector('[data-todo-new-thread-picker]');
    if (!select) return;
    select.innerHTML = threadOptions(threads, selectedID);
    select.hidden = !hasProject;
    select.disabled = !hasProject || threads.length === 0;
    select.value = selectedID && threads.some((thread) => thread.id === selectedID) ? selectedID : '';
  }

  function updateFilterOptions(projects, tags, items, filters = {}) {
    const projectFilter = document.querySelector('[data-todo-project-filter]');
    const tagFilter = document.querySelector('[data-todo-tag-filter]');
    if (projectFilter) projectFilter.innerHTML = filterProjectOptions(projects, items, filters.project || '');
    if (tagFilter) tagFilter.innerHTML = todoTagView.filterTagOptions(tags, items, filters.tag || '');
  }

  return { createPage, updateTopInset, render, sizeTitle, updateNavigation, updateNewProjectOptions, updateItemProjectOptions, updateThreadOptions, updateFilterOptions };
})();
