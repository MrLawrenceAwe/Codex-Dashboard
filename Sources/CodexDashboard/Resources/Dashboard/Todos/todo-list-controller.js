function createTodoList({ threadReferencesForProject }) {
  let items = todoStore.load();
  let availableTags = todoStore.loadTags(items);
  let projects = [];
  let projectDraft = null;
  let projectThreads = [];
  let threadDraft = null;
  let projectObserver;
  let observedProjectSidebar;
  let filterMode = 'open';
  let projectFilter = '';
  let tagFilter = '';
  let destroyed = false;
  let savedItems = items;
  let savedTags = availableTags;
  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.todoPage,
    navigationID: dashboardElements.elementIDs.todoNavButton,
    rootClass: 'codex-todo-open',
  });
  const imageController = createTodoImageController({
    isDestroyed: () => destroyed,
    getItems: () => items,
    updateItem,
  });
  const tagController = createTodoTagController({
    isDestroyed: () => destroyed,
    getAvailableTags: () => availableTags,
    getItems: () => items,
    commitChange: (nextTags, transformTag) => commitItems(items.map((item) => ({
      ...item, tags: item.tags.map(transformTag).filter(Boolean),
    })), nextTags),
  });

  function refreshProjects() {
    if (destroyed) return;
    projects = codexUIContracts.projects();
    const selected = projectDraft && projects.some((project) => project.id === projectDraft.id)
      ? projectDraft.id : '';
    if (!selected) projectDraft = null;
    todoListView.updateProjectOptions(projects, selected);
    refreshThreadOptions();
    updateFilterOptions();
  }

  function refreshThreadOptions() {
    if (destroyed) return;
    projectThreads = projectDraft ? threadReferencesForProject(projectDraft) : [];
    if (!projectThreads.some((thread) => thread.id === threadDraft?.id)) threadDraft = null;
    todoListView.updateThreadOptions(projectThreads, Boolean(projectDraft), threadDraft?.id || '');
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

  function renderTags() {
    if (destroyed) return;
    todoListView.updateTagOptions(availableTags);
    todoListView.updateManagedTags(availableTags, items);
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
    todoListView.updateFilterOptions(collectFilterProjects(), availableTags, items, {
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

  function loadItemImages() {
    todoStore.loadImages(items).then((hydratedItems) => {
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

  async function add(title, body = '', image = null, tags = [], project = null, thread = null) {
    const item = todoStore.create(title, body, image, tags);
    if (!item) return false;
    item.project = todoStore.normalizeProject(project);
    item.thread = todoStore.normalizeThread(thread);
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
    let addPending = false;
    page.querySelector('[data-todo-form]').addEventListener('submit', (event) => {
      event.preventDefault();
      if (addPending) return;
      const imageDraft = imageController.draft();
      if (imageDraft.status === 'invalid') {
        imageController.reset();
        return;
      }
      if (imageDraft.status === 'loading') {
        imageDraft.submitWhenReady = true;
        const imageStatus = page.querySelector('[data-todo-new-image-status]');
        imageStatus.textContent = 'Preparing image…';
        imageStatus.hidden = false;
        return;
      }
      imageController.setError();
      const title = page.querySelector('[data-todo-new-title]');
      const body = page.querySelector('[data-todo-new-body]');
      const submit = page.querySelector('[data-todo-form] button[type="submit"]');
      const submitted = {
        title: title.value,
        body: body.value,
        imageDraft,
        tags: tagController.draft(),
        project: projectDraft,
        thread: threadDraft,
      };
      addPending = true;
      submit.disabled = true;
      const finish = (saved) => {
        addPending = false;
        if (destroyed) return;
        submit.disabled = false;
        if (!saved || title.value !== submitted.title || body.value !== submitted.body
          || imageController.draft() !== submitted.imageDraft
          || tagController.draft() !== submitted.tags
          || projectDraft?.id !== submitted.project?.id
          || threadDraft?.id !== submitted.thread?.id) return;
        title.value = '';
        body.value = '';
        imageController.reset();
        tagController.reset();
        projectDraft = null;
        threadDraft = null;
        todoListView.updateProjectOptions(projects);
        refreshThreadOptions();
        title.focus();
      };
      const saved = add(
        submitted.title, submitted.body, imageDraft.image,
        submitted.tags, submitted.project, submitted.thread,
      );
      void saved.then(finish, () => finish(false));
    });
  }

  function bindDraftAssignments(page) {
    const projectInput = page.querySelector('[data-todo-new-project]');
    projectInput.addEventListener('change', () => {
      projectDraft = projects.find((project) => project.id === projectInput.value) || null;
      threadDraft = null;
      refreshThreadOptions();
    });
    page.querySelector('[data-todo-new-thread-picker]').addEventListener('change', (event) => {
      threadDraft = projectThreads.find((thread) => thread.id === event.target.value) || null;
    });
    tagController.bindDraft(page);
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
    page.querySelector('[data-todo-list]').addEventListener('input', (event) => {
      if (event.target.matches('[data-todo-title]')) todoListView.sizeTitle(event.target);
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
        const currentProjectID = items.find((item) => item.id === row.dataset.todoId)?.project?.id;
        const changes = { project };
        if (currentProjectID !== project?.id) changes.thread = null;
        void updateItem(row.dataset.todoId, changes);
      } else if (event.target.matches('[data-todo-tag]')) {
        const item = items.find((candidate) => candidate.id === row.dataset.todoId);
        if (item && event.target.value) void updateItem(item.id, {
          tags: todoStore.normalizeTags([...item.tags, event.target.value]),
        });
      }
    });
  }

  async function insertTodoIntoComposer(item) {
    if (destroyed) return false;
    const [loadedItem] = await todoStore.loadImages([item]);
    if (destroyed) return false;
    const content = [item.title, item.body].filter(Boolean).join('\n\n');
    const image = loadedItem?.image;
    let inserted = false;
    const transfer = () => {
      if (destroyed) return false;
      if (!inserted) inserted = composerAdapter.insert(content);
      return inserted && (!image || composerAdapter.attachImage(image));
    };
    if (transfer()) return true;
    const composer = await domUtils.waitFor(
      () => destroyed || codexUIContracts.composer(dashboardElements.elementIDs.promptDialog),
      { timeout: 3000, interval: 25 },
    );
    return Boolean(composer && !destroyed && transfer());
  }

  async function openTodoInNewThread(item) {
    if (destroyed || !item?.project || !await codexHost.newChat(item.project.id) || destroyed) return;
    pageState.close();
    await insertTodoIntoComposer(item);
  }

  async function pasteTodoInThread(item) {
    if (destroyed || !item?.thread) return;
    pageState.close();
    codexHost.navigateToThread(item.thread);
    const selected = await domUtils.waitFor(
      () => destroyed || codexUIContracts.isThreadSelected(item.thread.id),
      { timeout: 5000, interval: 25 },
    );
    if (selected && !destroyed) await insertTodoIntoComposer(item);
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
      const newThreadButton = event.target.closest('[data-todo-new-thread]');
      if (newThreadButton) {
        const row = newThreadButton.closest('[data-todo-id]');
        const item = items.find((candidate) => candidate.id === row?.dataset.todoId);
        void openTodoInNewThread(item);
        return;
      }
      const pasteInThreadButton = event.target.closest('[data-todo-paste-in-thread]');
      if (pasteInThreadButton) {
        const row = pasteInThreadButton.closest('[data-todo-id]');
        const item = items.find((candidate) => candidate.id === row?.dataset.todoId);
        void pasteTodoInThread(item);
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
    const existingPage = document.getElementById(dashboardElements.elementIDs.todoPage);
    if (existingPage) {
      todoListView.updateTopInset(existingPage);
      return true;
    }
    const pageHost = codexHost.pageHost();
    if (!pageHost) return false;
    const page = todoListView.createPage();
    bindAddForm(page);
    imageController.bind(page);
    bindDraftAssignments(page);
    tagController.bindManagement(page);
    bindFilters(page);
    bindItemEditing(page);
    bindItemActions(page);
    pageHost.append(page);
    todoListView.updateTopInset(page);
    renderTags();
    refreshProjects();
    startProjectObserver();
    pageState.applyVisibility();
    render();
    const writeProtectionReason = todoStore.writeProtectionReason();
    if (writeProtectionReason) {
      const notice = page.querySelector('[data-todo-storage-error]');
      notice.textContent = writeProtectionReason;
      notice.hidden = false;
      page.querySelectorAll('[data-todo-form] input, [data-todo-form] textarea, [data-todo-form] select, [data-todo-form] button, [data-todo-manage-tags]')
        .forEach((control) => { control.disabled = true; });
    }
    loadItemImages();
    return true;
  }

  function open() {
    if (!document.getElementById(dashboardElements.elementIDs.todoPage)) mountPage();
    const page = document.getElementById(dashboardElements.elementIDs.todoPage);
    if (page) todoListView.updateTopInset(page);
    refreshProjects();
    startProjectObserver();
    if (pageState.open()) render();
  }

  function destroy() {
    destroyed = true;
    projectObserver?.disconnect();
    projectObserver = undefined;
    observedProjectSidebar = undefined;
    imageController.destroy();
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
    refreshThreadOptions,
  };
}
