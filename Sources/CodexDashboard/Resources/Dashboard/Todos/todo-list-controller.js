const todoList = (() => {
  let items = todoListState.load();
  let availableTags = todoListState.loadTags(items);
  let projects = [];
  let projectDraft = null;
  let projectObserver;
  let filterMode = 'open';
  // Image saves use IndexedDB and therefore complete asynchronously. Keep every
  // snapshot in order so a slower, older save cannot overwrite a newer edit in
  // localStorage after it finishes.
  let persistenceTail = Promise.resolve();
  let persistencePending = false;
  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.todoPage,
    navigationID: dashboardElements.elementIDs.todoNavButton,
    rootClass: 'codex-todo-open',
  });
  let imageDraft;
  let tagDraft;
  resetImageDraft();
  resetTagDraft();

  function resetImageDraft() {
    imageDraft = { status: 'empty', image: null, submitWhenReady: false };
    todoListView?.updateImageDraft?.(null);
    const imageStatus = document.querySelector('[data-todo-new-image-status]');
    if (imageStatus) {
      imageStatus.hidden = true;
      imageStatus.textContent = '';
    }
  }

  function resetTagDraft() {
    tagDraft = [];
    todoListView?.updateTagDraft?.(tagDraft);
  }

  function refreshProjects() {
    projects = codexUIContracts.projects();
    const selected = projectDraft && projects.some((project) => project.id === projectDraft.id)
      ? projectDraft.id : '';
    if (!selected) projectDraft = null;
    todoListView?.updateProjectOptions?.(projects, selected);
  }

  function startProjectObserver() {
    if (projectObserver) return;
    const sidebar = codexHost.sidebar();
    if (!sidebar) return;
    projectObserver = new MutationObserver(refreshProjects);
    projectObserver.observe(sidebar, { childList: true, subtree: true, attributes: true,
      attributeFilter: ['data-app-action-sidebar-project-id', 'data-app-action-sidebar-project-label'] });
  }

  function addTagDraft(value) {
    if (!availableTags.includes(value)) return false;
    const tags = todoListState.normalizeTags([...tagDraft, value]);
    if (tags.length === tagDraft.length) return false;
    tagDraft = tags;
    todoListView.updateTagDraft(tagDraft);
    return true;
  }

  const acceptedImageTypes = new Set(['image/jpeg', 'image/png', 'image/gif', 'image/webp']);
  const maximumImageBytes = 2 * 1024 * 1024;

  function showImageError(message = '') {
    const notice = document.querySelector('[data-todo-image-error]');
    if (!notice) return;
    notice.textContent = message;
    notice.hidden = !message;
  }

  function persist(snapshot) {
    const notice = document.querySelector('[data-todo-storage-error]');
    const updateNotice = (result) => {
      if (notice) notice.hidden = result;
      return result;
    };
    const write = () => {
      const saved = todoListState.save(snapshot);
      return saved instanceof Promise ? saved : Promise.resolve(saved);
    };
    if (!persistencePending) {
      const saved = todoListState.save(snapshot);
      if (!(saved instanceof Promise)) return updateNotice(saved);
      persistencePending = true;
      persistenceTail = saved.then(updateNotice).finally(() => {
        persistencePending = false;
      });
      return persistenceTail;
    }
    // Recover the chain after a failed write: later changes must still have an
    // opportunity to become durable.
    persistenceTail = persistenceTail.catch(() => false).then(write).then(updateNotice)
      .finally(() => {
        persistencePending = false;
      });
    return persistenceTail;
  }

  function persistTags() {
    const saved = todoListState.saveTags(availableTags);
    const notice = document.querySelector('[data-todo-storage-error]');
    if (notice) notice.hidden = saved;
    return saved;
  }

  function renderTags() {
    todoListView.updateTagOptions(availableTags);
    todoListView.updateManagedTags(availableTags);
  }

  function render() {
    todoListView.render(items, filterMode, availableTags);
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
    render();
    const finish = (saved) => {
      if (saved) return true;
      if (items === nextItems) {
        items = previousItems;
        render();
      }
      return false;
    };
    const saved = persist(nextItems);
    return saved instanceof Promise ? saved.then(finish) : finish(saved);
  }

  function add(title, body = '', image = null, tags = [], projectTag = null) {
    const item = todoListState.create(title, body, image, tags);
    if (item) item.projectTag = todoListState.normalizeProjectTag(projectTag);
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
      const body = page.querySelector('[data-todo-new-body]');
      const finish = (saved) => {
        if (!saved) return;
        title.value = '';
        body.value = '';
        resetImageDraft();
        resetTagDraft();
        projectDraft = null;
        todoListView.updateProjectOptions(projects);
        title.focus();
      };
      const saved = add(title.value, body.value, imageDraft.image, tagDraft, projectDraft);
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
    page.querySelector('[data-todo-new-image-open]').addEventListener('click', () => {
      if (imageDraft.status === 'ready' && imageDraft.image) {
        todoListView.showImage(imageDraft.image);
      }
    });
    const tagInput = page.querySelector('[data-todo-new-tag]');
    const projectInput = page.querySelector('[data-todo-new-project]');
    projectInput.addEventListener('change', () => {
      projectDraft = projects.find((project) => project.id === projectInput.value) || null;
    });
    const addTag = () => {
      if (!addTagDraft(tagInput.value)) return;
      tagInput.value = '';
      tagInput.focus();
    };
    tagInput.addEventListener('change', addTag);
    page.querySelector('[data-todo-new-tags]').addEventListener('click', (event) => {
      const button = event.target.closest('[data-todo-tag-remove]');
      if (!button) return;
      tagDraft = tagDraft.filter((tag) => tag !== button.dataset.todoTagRemove);
      todoListView.updateTagDraft(tagDraft);
      tagInput.focus();
    });
    const tagDialog = document.querySelector('[data-todo-tag-dialog]');
    const closeTagDialog = () => {
      if (tagDialog.open) tagDialog.close();
    };
    page.querySelector('[data-todo-manage-tags]').addEventListener('click', () => {
      if (!tagDialog.open) tagDialog.showModal();
    });
    tagDialog.querySelector('[data-todo-tag-dialog-close]').addEventListener('click', closeTagDialog);
    tagDialog.addEventListener('click', (event) => {
      if (event.target === tagDialog) closeTagDialog();
    });
    tagDialog.querySelector('[data-todo-tag-form]').addEventListener('submit', (event) => {
      event.preventDefault();
      const name = tagDialog.querySelector('[data-todo-tag-name]');
      const previousTags = availableTags;
      const nextTags = todoListState.normalizeTags([...availableTags, name.value]);
      if (nextTags.length === availableTags.length) return;
      availableTags = nextTags;
      if (!persistTags()) {
        availableTags = previousTags;
        return;
      }
      name.value = '';
      renderTags();
      name.focus();
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
      } else if (event.target.matches('[data-todo-body]')) {
        void updateItem(row.dataset.todoId, { body: event.target.value });
      } else if (event.target.matches('[data-todo-project]')) {
        const project = codexUIContracts.projects()
          .find((candidate) => candidate.id === event.target.value) || null;
        void updateItem(row.dataset.todoId, { projectTag: project });
      } else if (event.target.matches('[data-todo-tag]')) {
        const item = items.find((candidate) => candidate.id === row.dataset.todoId);
        if (item && event.target.value) void updateItem(item.id, {
          tags: todoListState.normalizeTags([...item.tags, event.target.value]),
        });
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
      const newChatButton = event.target.closest('[data-todo-new-chat]');
      if (newChatButton) {
        const row = newChatButton.closest('[data-todo-id]');
        const item = items.find((candidate) => candidate.id === row?.dataset.todoId);
        const openNewChat = async () => {
          if (!item?.projectTag || !await codexHost.newChat(item.projectTag.id)) return;
          pageState.close();
          const content = [item.title, item.body].filter(Boolean).join('\n\n');
          let inserted = false;
          const transfer = async () => {
            let image = item.image;
            if (image && !image.dataURL) {
              const [hydratedItem] = await todoListState.hydrate([item]);
              image = hydratedItem?.image;
            }
            if (!inserted) inserted = composerAdapter.insert(content);
            if (!inserted) return false;
            return !image || composerAdapter.attachImage(image);
          };
          void transfer().then((transferred) => {
            if (transferred) return;
            return domUtils.waitFor(
              () => codexUIContracts.composer(dashboardElements.elementIDs.promptDialog),
              { timeout: 3000, interval: 25 },
            ).then((composer) => {
              if (composer) return transfer();
              return false;
            });
          });
        };
        void openNewChat();
        return;
      }
      const removeImageButton = event.target.closest('[data-todo-image-remove]');
      if (removeImageButton) {
        const row = removeImageButton.closest('[data-todo-id]');
        if (row) void updateItem(row.dataset.todoId, { image: null });
        return;
      }
      const removeTagButton = event.target.closest('[data-todo-tag-remove]');
      if (removeTagButton) {
        const row = removeTagButton.closest('[data-todo-id]');
        const item = items.find((candidate) => candidate.id === row?.dataset.todoId);
        if (item) void updateItem(item.id, {
          tags: item.tags.filter((tag) => tag !== removeTagButton.dataset.todoTagRemove),
        });
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
    renderTags();
    refreshProjects();
    startProjectObserver();
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
