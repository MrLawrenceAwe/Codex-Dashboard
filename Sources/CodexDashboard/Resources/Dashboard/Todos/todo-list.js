const todoList = (() => {
  let items = todoListState.load();
  let filterMode = 'open';
  const pageState = createDashboardPage({
    pageID: dashboardElements.elementIDs.todoPage,
    navigationID: dashboardElements.elementIDs.todoNavButton,
    rootClass: 'codex-todo-open',
  });
  let pendingNewImage = null;
  let pendingNewImageIsInvalid = false;
  let pendingNewImageIsLoading = false;
  let pendingNewImageSubmissionPending = false;
  const acceptedImageTypes = new Set(['image/jpeg', 'image/png', 'image/gif', 'image/webp']);
  const maximumImageBytes = 2 * 1024 * 1024;

  function showImageError(message = '') {
    const notice = document.querySelector('[data-todo-image-error]');
    if (!notice) return;
    notice.textContent = message;
    notice.hidden = !message;
  }

  function persist() {
    const saved = todoListState.save(items);
    const notice = document.querySelector('[data-todo-storage-error]');
    if (notice) notice.hidden = saved;
    return saved;
  }

  function render() {
    todoListView.render(items, filterMode);
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

  function readImage(file, onLoad, onError = () => {}) {
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
        onError();
        return;
      }
      onLoad(image);
    });
    reader.addEventListener('error', () => {
      showImageError('Codex could not read that image.');
      onError();
    });
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
        <span class="todo-nav-icon">${dashboardIcons.render('completed')}</span>
        <span>To-dos</span>
      </span>
      <strong class="todo-nav-count" data-todo-navigation-count aria-label="0 open to-dos" hidden>0</strong>`;
    if (insertionPoint.insertAfter) insertionPoint.element.after(button);
    else insertionPoint.element.parentElement.insertBefore(button, insertionPoint.element);
    todoListView.updateNavigation(items.filter((item) => !item.completed).length);
    pageState.restoreOpenState();
    return true;
  }

  function mountPage() {
    if (document.getElementById(dashboardElements.elementIDs.todoPage)) return true;
    const pageHost = codexHost.pageHost();
    if (!pageHost) return false;
    const page = todoListView.createPage();
    page.querySelector('[data-todo-form]').addEventListener('submit', (event) => {
      event.preventDefault();
      if (pendingNewImageIsInvalid) {
        pendingNewImageIsInvalid = false;
        return;
      }
      if (pendingNewImageIsLoading) {
        pendingNewImageSubmissionPending = true;
        const imageStatus = page.querySelector('[data-todo-new-image-status]');
        imageStatus.textContent = 'Preparing image…';
        imageStatus.hidden = false;
        return;
      }
      showImageError();
      const title = page.querySelector('[data-todo-new-title]');
      if (!add(title.value, pendingNewImage)) return;
      title.value = '';
      pendingNewImage = null;
      pendingNewImageIsInvalid = false;
      pendingNewImageIsLoading = false;
      pendingNewImageSubmissionPending = false;
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
        pendingNewImageIsLoading = false;
        pendingNewImageSubmissionPending = false;
        showImageError(validationError);
        return;
      }
      pendingNewImage = null;
      pendingNewImageIsInvalid = false;
      pendingNewImageIsLoading = true;
      pendingNewImageSubmissionPending = false;
      const imageStatus = page.querySelector('[data-todo-new-image-status]');
      imageStatus.textContent = 'Preparing image…';
      imageStatus.hidden = false;
      readImage(file, (image) => {
        pendingNewImage = image;
        pendingNewImageIsInvalid = false;
        pendingNewImageIsLoading = false;
        imageStatus.textContent = 'Image ready to attach when you add this to-do.';
        imageStatus.hidden = false;
        if (pendingNewImageSubmissionPending) {
          pendingNewImageSubmissionPending = false;
          page.querySelector('[data-todo-form]').requestSubmit();
        }
      }, () => {
        pendingNewImageIsLoading = false;
        pendingNewImageSubmissionPending = false;
        imageStatus.hidden = true;
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
        if (item?.image) todoListView.showImage(item.image);
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
    pageHost.append(page);
    pageState.restoreOpenState();
    render();
    return true;
  }

  function open() {
    if (!document.getElementById(dashboardElements.elementIDs.todoPage)) mountPage();
    if (pageState.open()) render();
  }

  return {
    close: pageState.close,
    destroy: pageState.close,
    isOpen: pageState.isOpen,
    mountNavigation,
    mountPage,
    open,
    restoreOpenState: pageState.restoreOpenState,
  };
})();
