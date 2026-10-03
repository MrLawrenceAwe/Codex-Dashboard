function createTodoList({ threadReferencesForProject, findThread }) {
  let items = todoStore.load();
  let availableTags = todoStore.loadTags(items);
  let projects = [];
  let projectObserver;
  let observedProjectSidebar;
  let filterMode = 'open';
  let projectFilter = '';
  let tagFilter = '';
  let destroyed = false;
  let savedItems = items;
  let savedTags = availableTags;
  let pendingWrites = 0;
  let storageRefreshPending = false;
  let commitQueue = Promise.resolve();
  let expandedPresetTodoID = null;
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
  const composerActions = createTodoComposerActions({
    isDestroyed: () => destroyed,
    pageState,
    threadReferencesForProject,
    getItems: () => items,
  });
  const tagController = createTodoTagController({
    isDestroyed: () => destroyed,
    getAvailableTags: () => availableTags,
    getItems: () => items,
    commitChange: (nextTags, transformTag) => commitItems(items.map((item) => ({
      ...item, tags: item.tags.map(transformTag).filter(Boolean),
    })), nextTags),
  });

  const createForm = createTodoCreateForm({
    imageController,
    tagController,
    threadReferencesForProject,
    isDestroyed: () => destroyed,
    onSubmit: addTodo,
  });

  const sidebarActions = createSidebarThreadTodoActions({
    findThread,
    getItems: () => items,
    addTodo,
  });

  function refreshProjects() {
    if (destroyed) return;
    projects = codexUIContracts.projects();
    createForm.updateProjects(projects);
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

  function renderTags() {
    if (destroyed) return;
    todoListView.updateTagOptions(availableTags);
    todoListView.updateManagedTags(availableTags, items);
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
    sidebarActions.refresh();
    const selectableProjects = collectFilterProjects();
    if (projectFilter !== '__none__'
      && projectFilter
      && !selectableProjects.some((project) => project.id === projectFilter)) {
      projectFilter = '';
    }
    if (tagFilter && !availableTags.includes(tagFilter)) tagFilter = '';
    todoListView.render(items, filterMode, availableTags, selectableProjects, {
      project: projectFilter,
      tag: tagFilter,
    });
    if (expandedPresetTodoID) {
      const row = [...document.querySelectorAll('[data-todo-id]')]
        .find((candidate) => candidate.dataset.todoId === expandedPresetTodoID);
      row?.querySelector('[data-todo-preset-details]')?.setAttribute('open', '');
    }
  }

  function loadItemImages() {
    todoImageStore.load(items).then((hydratedItems) => {
      if (destroyed) return;
      const hydratedImages = new Map(hydratedItems.map((item) => [item.id, item.image]));
      const hydrate = (item) => {
        const image = hydratedImages.get(item.id);
        if (!item.image || item.image.dataURL || !image?.dataURL
          || item.image.storageKey !== image.storageKey) return item;
        return { ...item, image: { ...item.image, dataURL: image.dataURL } };
      };
      const updatedImages = [];
      items = items.map((item) => {
        const updated = hydrate(item);
        if (updated !== item) updatedImages.push(updated);
        return updated;
      });
      savedItems = savedItems.map(hydrate);
      todoListView.showHydratedImages(updatedImages);
    });
  }

  function hasActiveTextDraft() {
    const editor = document.activeElement;
    if (!editor?.matches('[data-todo-title], [data-todo-body]')) return false;
    const item = items.find((candidate) => candidate.id === editor.closest('[data-todo-id]')?.dataset.todoId);
    const field = editor.matches('[data-todo-title]') ? 'title' : 'body';
    return item && editor.value !== item[field];
  }

  function refreshFromStorage() {
    if (destroyed || pendingWrites || todoStore.writeProtectionReason()) return;
    // Text edits commit on change (usually blur). Keep the editor and its
    // selection intact until then, retaining the baseline for the save's merge.
    if (hasActiveTextDraft()) {
      storageRefreshPending = true;
      return;
    }
    storageRefreshPending = false;
    const loadedItems = todoStore.load();
    const imagesByID = new Map(items.filter((item) => item.image?.dataURL)
      .map((item) => [item.id, item.image]));
    items = loadedItems.map((item) => {
      const image = imagesByID.get(item.id);
      return item.image && !item.image.dataURL && image?.storageKey === item.image.storageKey
        ? { ...item, image: { ...item.image, dataURL: image.dataURL } }
        : item;
    });
    availableTags = todoStore.loadTags(items);
    savedItems = items;
    savedTags = availableTags;
    renderTags();
    render();
    loadItemImages();
  }

  function handleStorageChange(event) {
    if (event.key === todoStore.storageKey || event.key === todoStore.tagsStorageKey) {
      refreshFromStorage();
    }
  }

  window.addEventListener('storage', handleStorageChange);

  async function commitItems(nextItems, nextTags = availableTags) {
    if (destroyed) return false;
    pendingWrites += 1;
    items = nextItems;
    availableTags = nextTags;
    renderTags();
    render();
    // Resolve the baseline only after earlier commits finish. Advance it on
    // success so an undo remains a change; retain it on failure so later edits
    // retry all changes still present in the optimistic snapshot.
    const saving = commitQueue.then(async () => {
      const saved = await todoStore.save(nextItems, nextTags, savedItems, savedTags);
      if (saved) {
        savedItems = nextItems;
        savedTags = nextTags;
      }
      return saved;
    }).catch(() => false);
    commitQueue = saving;
    const saved = await saving;
    pendingWrites -= 1;
    if (destroyed) return saved;
    const notice = document.querySelector('[data-todo-storage-error]');
    if (notice) notice.hidden = saved;
    if (!pendingWrites) {
      if (todoStore.writeProtectionReason()) {
        items = savedItems;
        availableTags = savedTags;
        renderTags();
        render();
      } else refreshFromStorage();
    }
    return saved;
  }

  async function addTodo({ title, body = '', image = null, tags = [], project = null, thread = null, preset = null }) {
    const item = todoStore.create(title, body, image, tags);
    if (!item) return false;
    item.project = todoStore.normalizeProject(project);
    item.thread = todoStore.normalizeThread(thread);
    item.preset = composerPresets.normalize(preset) || null;
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
      afterID: dashboardElements.elementIDs.chatOverviewNavButton,
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

  function mountPage() {
    sidebarActions.mount();
    const existingPage = document.getElementById(dashboardElements.elementIDs.todoPage);
    if (existingPage) {
      todoListView.updateTopInset(existingPage);
      return true;
    }
    const pageHost = codexHost.pageHost();
    if (!pageHost) return false;
    const page = todoListView.createPage();
    createForm.bind(page);
    imageController.bind(page);
    tagController.bindManagement(page);
    bindFilters(page);
    page.addEventListener('focusout', () => {
      // Let change handlers and the next focus target settle before refreshing.
      queueMicrotask(() => {
        if (storageRefreshPending) refreshFromStorage();
      });
    });
    bindTodoItemInteractions(page, {
      getItems: () => items,
      updateItem,
      commitItems,
      composerActions,
      readPreset: todoListView.readPreset,
      render,
      setExpandedPresetTodoID: (id) => { expandedPresetTodoID = id; },
    });
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
    window.removeEventListener('storage', handleStorageChange);
    projectObserver?.disconnect();
    projectObserver = undefined;
    observedProjectSidebar = undefined;
    imageController.destroy();
    sidebarActions.destroy();
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
    refreshThreadOptions: createForm.refreshThreadOptions,
    refreshSidebarActions: sidebarActions.refresh,
  };
}
