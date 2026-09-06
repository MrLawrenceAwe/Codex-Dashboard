const todoList = (() => {
  let items = todoListState.load();
  let filterMode = 'open';
  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.todoPage,
    navigationID: dashboardElements.elementIDs.todoNavButton,
    rootClass: 'codex-todo-open',
  });
  let imageDraft;
  resetImageDraft();

  function resetImageDraft() {
    imageDraft = { status: 'empty', image: null, submitWhenReady: false };
    todoListView?.updateImageDraft?.(null);
    const imageStatus = document.querySelector('[data-todo-new-image-status]');
    if (imageStatus) {
      imageStatus.hidden = true;
      imageStatus.textContent = '';
    }
  }

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
    const updateNotice = (result) => {
      if (notice) notice.hidden = result;
      return result;
    };
    return saved instanceof Promise ? saved.then(updateNotice) : updateNotice(saved);
  }

  function render() {
    todoListView.render(items, filterMode);
  }

  function hydrateImages() {
    todoListState.hydrate(items).then((hydratedItems) => {
      const hydratedImages = new Map(hydratedItems.map((item) => [item.id, item.image?.dataURL]));
      let changed = false;
      items = items.map((item) => {
        const dataURL = hydratedImages.get(item.id);
        if (!item.image || item.image.dataURL || !dataURL) return item;
        changed = true;
        return { ...item, image: { ...item.image, dataURL } };
      });
      if (changed) render();
    });
  }

  function commitItems(nextItems) {
    const previousItems = items;
    items = nextItems;
    const finish = (saved) => {
      if (saved) {
        render();
        return true;
      }
      if (items === nextItems) {
        items = previousItems;
        render();
      }
      return false;
    };
    const saved = persist();
    return saved instanceof Promise ? saved.then(finish) : finish(saved);
  }

  function add(title, image = null) {
    const item = todoListState.create(title, image);
    if (!item) return false;
    const finish = (saved) => {
      if (!saved) return false;
      filterMode = 'open';
      render();
      return true;
    };
    const saved = commitItems([item, ...items]);
    return saved instanceof Promise ? saved.then(finish) : finish(saved);
  }

  function updateItem(id, changes) {
    const nextItems = items.map((item) => item.id === id
      ? todoListState.normalizeItem({ ...item, ...changes, updatedAt: Date.now() }) || item
      : item);
    return commitItems(nextItems);
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
    if (!mountDashboardNavigationButton({
      id: dashboardElements.elementIDs.todoNavButton,
      label: 'To-dos',
      afterID: dashboardElements.elementIDs.navButton,
      markup: `
      <span class="todo-nav-copy">
        <span class="todo-nav-icon">${dashboardIcons.render('completed')}</span>
        <span>To-dos</span>
      </span>
      <strong class="todo-nav-count" data-todo-navigation-count aria-label="0 open to-dos" hidden>0</strong>`,
    })) return false;
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
      if (imageDraft.status === 'invalid') {
        resetImageDraft();
        return;
      }
      if (imageDraft.status === 'loading') {
        imageDraft.submitWhenReady = true;
        const imageStatus = page.querySelector('[data-todo-new-image-status]');
        imageStatus.textContent = 'Preparing image…';
        imageStatus.hidden = false;
        return;
      }
      showImageError();
      const title = page.querySelector('[data-todo-new-title]');
      const finish = (saved) => {
        if (!saved) return;
        title.value = '';
        resetImageDraft();
        title.focus();
      };
      const saved = add(title.value, imageDraft.image);
      if (saved instanceof Promise) void saved.then(finish);
      else finish(saved);
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
        resetImageDraft();
        imageDraft.status = 'invalid';
        showImageError(validationError);
        return;
      }
      resetImageDraft();
      imageDraft.status = 'loading';
      const readingDraft = imageDraft;
      const imageStatus = page.querySelector('[data-todo-new-image-status]');
      imageStatus.textContent = 'Preparing image…';
      imageStatus.hidden = false;
      readImage(file, (image) => {
        if (imageDraft !== readingDraft) return;
        imageDraft.image = image;
        imageDraft.status = 'ready';
        todoListView.updateImageDraft(image);
        imageStatus.textContent = 'Image ready to attach when you add this to-do.';
        imageStatus.hidden = false;
        if (imageDraft.submitWhenReady) {
          imageDraft.submitWhenReady = false;
          page.querySelector('[data-todo-form]').requestSubmit();
        }
      }, () => {
        if (imageDraft !== readingDraft) return;
        resetImageDraft();
        imageDraft.status = 'invalid';
        imageStatus.hidden = true;
      });
    });
    page.querySelector('[data-todo-new-image-remove]').addEventListener('click', () => {
      resetImageDraft();
      showImageError();
      page.querySelector('[data-todo-new-title]').focus();
    });
    page.querySelectorAll('[data-todo-filter]').forEach((button) => {
      button.addEventListener('click', () => {
        filterMode = button.dataset.todoFilter;
        render();
      });
    });
    page.querySelector('[data-todo-clear-completed]').addEventListener('click', () => {
      void commitItems(items.filter((item) => !item.completed));
    });
    page.querySelector('[data-todo-list]').addEventListener('change', (event) => {
      const row = event.target.closest('[data-todo-id]');
      if (!row) return;
      if (event.target.matches('[data-todo-completed]')) {
        void updateItem(row.dataset.todoId, { completed: event.target.checked });
      } else if (event.target.matches('[data-todo-title]')) {
        const title = event.target.value.trim();
        if (title) void updateItem(row.dataset.todoId, { title });
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
        if (row) void updateItem(row.dataset.todoId, { image: null });
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
      void commitItems(items.filter((item) => item.id !== row.dataset.todoId));
    });
    pageHost.append(page);
    pageState.restoreOpenState();
    render();
    hydrateImages();
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
