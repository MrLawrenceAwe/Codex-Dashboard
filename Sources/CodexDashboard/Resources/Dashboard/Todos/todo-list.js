const todoList = (() => {
  let items = todoListState.load();
  let filterMode = 'open';
  let pageIsOpen = false;
  let pendingNewImage = null;
  let pendingNewImageIsInvalid = false;
  const acceptedImageTypes = new Set(['image/jpeg', 'image/png', 'image/gif', 'image/webp']);
  const maximumImageBytes = 2 * 1024 * 1024;

  function showImageError(message = '') {
    const notice = document.querySelector('[data-todo-image-error]');
    if (!notice) return;
    notice.textContent = message;
    notice.hidden = !message;
  }

  function imageMarkup(item) {
    if (!item.image) return '';
    const name = dashboardElements.escapeHTML(item.image.name);
    return `
      <div class="todo-image">
        <button type="button" class="todo-image-preview" data-todo-image-preview aria-label="View image: ${name}" title="View image">
          <img src="${dashboardElements.escapeHTML(item.image.dataURL)}" alt="${name}">
        </button>
        <span class="todo-image-name" title="${name}">${name}</span>
      </div>`;
  }

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
      const message = !items.length ? 'No to-dos yet'
        : filterMode === 'completed' ? 'No completed to-dos' : 'All caught up';
      list.innerHTML = `<div class="todo-empty"><span class="todo-empty-icon" aria-hidden="true">${threadMarkup.icon('completed')}</span><strong>${message}</strong></div>`;
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
          ${imageMarkup(item)}
          ${item.completed ? '' : `<div class="todo-image-actions">
            <span class="todo-image-paste-hint">Paste an image into the title to ${item.image ? 'replace' : 'attach'} it.</span>
            ${item.image ? '<button type="button" data-todo-image-remove>Remove image</button>' : ''}
          </div>`}
        </div>
        <button type="button" class="todo-delete" data-todo-delete aria-label="Delete ${dashboardElements.escapeHTML(item.title)}" title="Delete to-do">
          <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13M10 11v5m4-5v5"/></svg>
        </button>
      </article>
    `).join('');
  }

  function add(title, image = null) {
    const item = todoListState.create(title, image);
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

  function imageValidationError(file) {
    if (!acceptedImageTypes.has(file?.type)) {
      return 'Choose a JPEG, PNG, GIF, or WebP image.';
    }
    if (file.size > maximumImageBytes) {
      return 'Images must be 2 MB or smaller.';
    }
    return '';
  }

  function readImage(file, onLoad) {
    showImageError();
    const validationError = imageValidationError(file);
    if (validationError) {
      showImageError(validationError);
      return false;
    }
    const reader = new FileReader();
    reader.addEventListener('load', () => {
      const image = todoListState.normalizeImage({
        dataURL: reader.result,
        name: file.name,
        type: file.type,
        size: file.size,
      });
      if (!image) {
        showImageError('Codex could not read that image.');
        return;
      }
      onLoad(image);
    });
    reader.addEventListener('error', () => showImageError('Codex could not read that image.'));
    reader.readAsDataURL(file);
    return true;
  }

  function attachImage(id, file) {
    const item = items.find((candidate) => candidate.id === id);
    if (!item || item.completed) return;
    readImage(file, (image) => updateItem(id, { image }));
  }

  function pastedImage(event) {
    const clipboard = event.clipboardData;
    if (!clipboard) return null;
    return Array.from(clipboard.files || []).find((file) => file.type.startsWith('image/'))
      || Array.from(clipboard.items || []).find((item) => item.kind === 'file' && item.type.startsWith('image/'))?.getAsFile()
      || null;
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
    page.querySelector('[data-todo-form]').addEventListener('submit', (event) => {
      event.preventDefault();
      if (pendingNewImageIsInvalid) {
        pendingNewImageIsInvalid = false;
        return;
      }
      showImageError();
      const title = page.querySelector('[data-todo-new-title]');
      if (!add(title.value, pendingNewImage)) return;
      title.value = '';
      pendingNewImage = null;
      pendingNewImageIsInvalid = false;
      const imageStatus = page.querySelector('[data-todo-new-image-status]');
      imageStatus.hidden = true;
      imageStatus.textContent = '';
      title.focus();
    });
    page.addEventListener('paste', (event) => {
      const file = pastedImage(event);
      if (!file) return;
      const row = event.target.closest('[data-todo-id]');
      if (row) {
        event.preventDefault();
        attachImage(row.dataset.todoId, file);
        return;
      }
      if (!event.target.closest('[data-todo-form]')) return;
      event.preventDefault();
      const validationError = imageValidationError(file);
      if (validationError) {
        pendingNewImage = null;
        pendingNewImageIsInvalid = true;
        showImageError(validationError);
        return;
      }
      readImage(file, (image) => {
        pendingNewImage = image;
        pendingNewImageIsInvalid = false;
        const imageStatus = page.querySelector('[data-todo-new-image-status]');
        imageStatus.textContent = 'Image ready to attach when you add this to-do.';
        imageStatus.hidden = false;
      });
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
      const previewButton = event.target.closest('[data-todo-image-preview]');
      if (previewButton) {
        const row = previewButton.closest('[data-todo-id]');
        const item = items.find((candidate) => candidate.id === row?.dataset.todoId);
        const dialog = page.querySelector('[data-todo-image-dialog]');
        if (item?.image && dialog) {
          const image = dialog.querySelector('img');
          image.src = item.image.dataURL;
          image.alt = item.image.name;
          dialog.showModal();
        }
        return;
      }
      const removeImageButton = event.target.closest('[data-todo-image-remove]');
      if (removeImageButton) {
        const row = removeImageButton.closest('[data-todo-id]');
        if (row) updateItem(row.dataset.todoId, { image: null });
        return;
      }
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
