const todoList = (() => {
  let items = todoStore.load();
  let availableTags = todoStore.loadTags(items);
  let projects = [];
  let projectDraft = null;
  let projectObserver;
  let observedProjectSidebar;
  let filterMode = 'open';
  let projectFilter = '';
  let tagFilter = '';
  let destroyed = false;
  let savedItems = items;
  let savedTags = availableTags;
  const imageReaders = new Set();
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
    if (destroyed) return;
    projects = codexUIContracts.projects();
    const selected = projectDraft && projects.some((project) => project.id === projectDraft.id)
      ? projectDraft.id : '';
    if (!selected) projectDraft = null;
    todoListView?.updateProjectOptions?.(projects, selected);
    updateFilterOptions();
  }

  function startProjectObserver() {
    const sidebar = codexHost.sidebar();
    if (sidebar === observedProjectSidebar) return;
    if (!projectObserver) projectObserver = new MutationObserver(refreshProjects);
    projectObserver.disconnect();
    observedProjectSidebar = sidebar;
    if (!sidebar) return;
    projectObserver.observe(sidebar, { childList: true, subtree: true, attributes: true,
      attributeFilter: ['data-app-action-sidebar-project-id', 'data-app-action-sidebar-project-label'] });
  }

  function addTagDraft(value) {
    if (!availableTags.includes(value)) return false;
    const tags = todoStore.normalizeTags([...tagDraft, value]);
    if (tags.length === tagDraft.length) return false;
    tagDraft = tags;
    todoListView.updateTagDraft(tagDraft);
    return true;
  }

  const acceptedImageTypes = new Set(['image/jpeg', 'image/png', 'image/gif', 'image/webp']);
  const maximumImageBytes = 2 * 1024 * 1024;

  function showImageError(message = '') {
    if (destroyed) return;
    const notice = document.querySelector('[data-todo-image-error]');
    if (!notice) return;
    notice.textContent = message;
    notice.hidden = !message;
  }

  function renderTags() {
    if (destroyed) return;
    todoListView.updateTagOptions(availableTags);
    todoListView.updateManagedTags(availableTags);
    updateFilterOptions();
  }

  function collectFilterProjects() {
    const projectMap = new Map(projects.map((project) => [project.id, project]));
    items.forEach((item) => {
      if (item.project && !projectMap.has(item.project.id)) {
        projectMap.set(item.project.id, item.project);
      }
    });
    return [...projectMap.values()];
  }

  function updateFilterOptions() {
    todoListView?.updateFilterOptions?.(collectFilterProjects(), availableTags, items, {
      project: projectFilter,
      tag: tagFilter,
    });
  }

  function render() {
    if (destroyed) return;
    const selectableProjects = collectFilterProjects();
    if (projectFilter !== '__none__'
      && projectFilter
      && !selectableProjects.some((project) => project.id === projectFilter)) {
      projectFilter = '';
    }
    if (tagFilter && !availableTags.includes(tagFilter)) tagFilter = '';
    todoListView.render(items, filterMode, availableTags, collectFilterProjects(), {
      project: projectFilter,
      tag: tagFilter,
    });
  }

  function hydrateImages() {
    todoStore.hydrate(items).then((hydratedItems) => {
      if (destroyed) return;
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

  async function commitItems(nextItems, nextTags = availableTags) {
    if (destroyed) return false;
    items = nextItems;
    availableTags = nextTags;
    renderTags();
    render();
    const saved = await todoStore.save(nextItems, nextTags);
    if (saved) {
      savedItems = nextItems;
      savedTags = nextTags;
    }
    if (destroyed) return saved;
    const notice = document.querySelector('[data-todo-storage-error]');
    if (notice) notice.hidden = saved;
    if (!saved && items === nextItems) {
      items = savedItems;
      availableTags = savedTags;
      renderTags();
      render();
    }
    return saved;
  }

  async function commitTagChange(nextTags, transformTag = (tag) => tag) {
    const previousDraft = tagDraft;
    const nextDraft = tagDraft.map(transformTag).filter(Boolean);
    tagDraft = nextDraft;
    todoListView.updateTagDraft(tagDraft);
    const saved = await commitItems(items.map((item) => ({
      ...item, tags: item.tags.map(transformTag).filter(Boolean),
    })), nextTags);
    if (!saved && !destroyed && tagDraft === nextDraft) {
      tagDraft = previousDraft;
      todoListView.updateTagDraft(tagDraft);
    }
    return saved;
  }

  async function add(title, body = '', image = null, tags = [], project = null) {
    const item = todoStore.create(title, body, image, tags);
    if (!item) return false;
    item.project = todoStore.normalizeProject(project);
    const saved = await commitItems([item, ...items]);
    if (saved && !destroyed) {
      filterMode = 'open';
      render();
    }
    return saved;
  }

  function updateItem(id, changes) {
    const nextItems = items.map((item) => item.id === id
      ? todoStore.normalizeItem({ ...item, ...changes, updatedAt: Date.now() }) || item
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
    imageReaders.add(reader);
    reader.addEventListener('loadend', () => imageReaders.delete(reader));
    reader.addEventListener('load', () => {
      if (destroyed) return;
      const image = todoStore.normalizeImage({
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
      if (destroyed) return;
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
      afterID: dashboardElements.elementIDs.taskNavButton,
      markup: `
      <span class="todo-nav-copy">
        <span class="todo-nav-icon">${dashboardIcons.render('completed')}</span>
        <span>To-dos</span>
      </span>
      <strong class="todo-nav-count" data-todo-navigation-count aria-label="0 open to-dos" hidden>0</strong>`,
    })) return false;
    todoListView.updateNavigation(items.filter((item) => !item.completed).length);
    pageState.applyVisibility();
    return true;
  }

  function bindAddForm(page) {
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
        if (!saved || destroyed) return;
        title.value = '';
        body.value = '';
        resetImageDraft();
        resetTagDraft();
        projectDraft = null;
        todoListView.updateProjectOptions(projects);
        title.focus();
      };
      const saved = add(title.value, body.value, imageDraft.image, tagDraft, projectDraft);
      void saved.then(finish);
    });
  }

  function bindImageDraft(page) {
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
  }

  function bindDraftAssignments(page) {
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
  }

  function bindTagManagement(page) {
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
    const tagNameInput = tagDialog.querySelector('[data-todo-tag-name]');
    const tagFormButton = tagDialog.querySelector('[data-todo-tag-form] button[type="submit"]');
    const resetTagForm = () => {
      tagNameInput.value = '';
      delete tagNameInput.dataset.todoTagRename;
      tagNameInput.setAttribute('aria-label', 'Tag name');
      tagFormButton.textContent = 'Create tag';
    };
    tagDialog.querySelector('[data-todo-tag-form]').addEventListener('submit', (event) => {
      event.preventDefault();
      const name = tagNameInput;
      const oldTag = name.dataset.todoTagRename;
      const replacement = todoStore.normalizeTags([name.value])[0];
      if (oldTag && availableTags.some((tag) => tag !== oldTag
        && tag.toLocaleLowerCase() === replacement?.toLocaleLowerCase())) return;
      const nextTags = oldTag
        ? todoStore.normalizeTags(availableTags.map((tag) => tag === oldTag ? name.value : tag))
        : todoStore.normalizeTags([...availableTags, name.value]);
      if (!replacement || (!oldTag && nextTags.length === availableTags.length)
        || (oldTag && nextTags.every((tag, index) => tag === availableTags[index]))) return;
      void commitTagChange(nextTags, (tag) => tag === oldTag ? replacement : tag);
      resetTagForm();
      name.focus();
    });
    tagDialog.querySelector('[data-todo-managed-tags]').addEventListener('click', (event) => {
      const editButton = event.target.closest('[data-todo-managed-tag-edit]');
      if (editButton) {
        tagNameInput.value = editButton.dataset.todoManagedTagEdit;
        tagNameInput.dataset.todoTagRename = editButton.dataset.todoManagedTagEdit;
        tagNameInput.setAttribute('aria-label', `Rename tag ${editButton.dataset.todoManagedTagEdit}`);
        tagFormButton.textContent = 'Save tag';
        tagNameInput.focus();
        tagNameInput.select();
        return;
      }
      const button = event.target.closest('[data-todo-managed-tag-remove]');
      if (!button) return;
      const tag = button.dataset.todoManagedTagRemove;
      const nextTags = availableTags.filter((candidate) => candidate !== tag);
      if (nextTags.length === availableTags.length) return;
      if (tagNameInput.dataset.todoTagRename === tag) resetTagForm();
      void commitTagChange(nextTags, (candidate) => candidate === tag ? null : candidate);
    });
  }

  function bindFilters(page) {
    page.querySelectorAll('[data-todo-filter]').forEach((button) => {
      button.addEventListener('click', () => {
        filterMode = button.dataset.todoFilter;
        render();
      });
    });
    page.querySelector('[data-todo-project-filter]').addEventListener('change', (event) => {
      projectFilter = event.target.value;
      render();
    });
    page.querySelector('[data-todo-tag-filter]').addEventListener('change', (event) => {
      tagFilter = event.target.value;
      render();
    });
    page.querySelector('[data-todo-clear-completed]').addEventListener('click', () => {
      void commitItems(items.filter((item) => !item.completed));
    });
  }

  function bindItemEditing(page) {
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
        void updateItem(row.dataset.todoId, { project });
      } else if (event.target.matches('[data-todo-tag]')) {
        const item = items.find((candidate) => candidate.id === row.dataset.todoId);
        if (item && event.target.value) void updateItem(item.id, {
          tags: todoStore.normalizeTags([...item.tags, event.target.value]),
        });
      }
    });
  }

  async function openTodoInNewChat(item) {
    if (destroyed || !item?.project || !await codexHost.newChat(item.project.id) || destroyed) return;
    pageState.close();
    const content = [item.title, item.body].filter(Boolean).join('\n\n');
    let inserted = false;
    const transfer = async () => {
      if (destroyed) return false;
      let image = item.image;
      if (image && !image.dataURL) {
        const [hydratedItem] = await todoStore.hydrate([item]);
        image = hydratedItem?.image;
      }
      if (destroyed) return false;
      if (!inserted) inserted = composerAdapter.insert(content);
      if (!inserted) return false;
      return !image || composerAdapter.attachImage(image);
    };
    if (await transfer() || destroyed) return;
    const composer = await domUtils.waitFor(
      () => destroyed || codexUIContracts.composer(dashboardElements.elementIDs.promptDialog),
      { timeout: 3000, interval: 25 },
    );
    if (composer && !destroyed) await transfer();
  }

  function bindItemActions(page) {
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
        void openTodoInNewChat(item);
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
  }

  function mountPage() {
    if (document.getElementById(dashboardElements.elementIDs.todoPage)) return true;
    const pageHost = codexHost.pageHost();
    if (!pageHost) return false;
    const page = todoListView.createPage();
    bindAddForm(page);
    bindImageDraft(page);
    bindDraftAssignments(page);
    bindTagManagement(page);
    bindFilters(page);
    bindItemEditing(page);
    bindItemActions(page);
    pageHost.append(page);
    renderTags();
    refreshProjects();
    startProjectObserver();
    pageState.applyVisibility();
    render();
    hydrateImages();
    return true;
  }

  function open() {
    if (!document.getElementById(dashboardElements.elementIDs.todoPage)) mountPage();
    refreshProjects();
    startProjectObserver();
    if (pageState.open()) render();
  }

  function destroy() {
    destroyed = true;
    projectObserver?.disconnect();
    projectObserver = undefined;
    observedProjectSidebar = undefined;
    imageReaders.forEach((reader) => reader.abort());
    imageReaders.clear();
    pageState.close();
  }

  return {
    close: pageState.close,
    destroy,
    isOpen: pageState.isOpen,
    mountNavigation,
    mountPage,
    open,
    applyVisibility: pageState.applyVisibility,
  };
})();
