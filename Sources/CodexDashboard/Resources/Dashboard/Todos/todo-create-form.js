function createTodoCreateForm({ imageController, tagController, threadReferencesForProject, isDestroyed, onSubmit }) {
  let projects = [];
  let selectedProject = null;
  let projectThreads = [];
  let selectedThread = null;

  function updateProjects(nextProjects) {
    projects = nextProjects;
    selectedProject = projects.find((project) => project.id === selectedProject?.id) || null;
    todoListView.updateNewProjectOptions(projects, selectedProject?.id || '');
    refreshThreadOptions();
  }

  function refreshThreadOptions() {
    if (isDestroyed()) return;
    projectThreads = selectedProject ? threadReferencesForProject(selectedProject) : [];
    if (!projectThreads.some((thread) => thread.id === selectedThread?.id)) selectedThread = null;
    todoListView.updateThreadOptions(projectThreads, Boolean(selectedProject), selectedThread?.id || '');
  }

  function readTodoDraft(page) {
    return {
      title: page.querySelector('[data-todo-new-title]').value,
      body: page.querySelector('[data-todo-new-body]').value,
      imageDraft: imageController.draft(),
      tags: tagController.draft(),
      project: selectedProject,
      thread: selectedThread,
      preset: todoFormValues.readPreset(page.querySelector('[data-todo-new-preset-enabled]'), page.querySelector('[data-todo-new-preset-fields]')),
    };
  }

  function draftStillMatches(page, submitted) {
    const current = readTodoDraft(page);
    return current.title === submitted.title && current.body === submitted.body
      && current.imageDraft === submitted.imageDraft && current.tags === submitted.tags
      && current.project?.id === submitted.project?.id
      && current.thread?.id === submitted.thread?.id
      && JSON.stringify(current.preset) === JSON.stringify(submitted.preset);
  }

  function bind(page) {
    bindDraftAssignments(page);
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
      const submitted = readTodoDraft(page);
      addPending = true;
      submit.disabled = true;
      const finish = (saved) => {
        addPending = false;
        if (isDestroyed()) return;
        submit.disabled = false;
        if (!saved || !draftStillMatches(page, submitted)) return;
        title.value = '';
        body.value = '';
        imageController.reset();
        tagController.reset();
        selectedProject = null;
        selectedThread = null;
        page.querySelector('[data-todo-new-preset-enabled]').checked = false;
        page.querySelector('[data-todo-new-preset-fields]').hidden = true;
        todoListView.updateNewProjectOptions(projects);
        refreshThreadOptions();
        title.focus();
      };
      const saved = onSubmit({ ...submitted, image: imageDraft.image });
      void saved.then(finish, () => finish(false));
    });
  }

  function bindDraftAssignments(page) {
    page.querySelector('[data-todo-new-preset-enabled]').addEventListener('change', (event) => {
      page.querySelector('[data-todo-new-preset-fields]').hidden = !event.target.checked;
    });
    const projectInput = page.querySelector('[data-todo-new-project]');
    projectInput.addEventListener('change', () => {
      selectedProject = projects.find((project) => project.id === projectInput.value) || null;
      selectedThread = null;
      refreshThreadOptions();
    });
    page.querySelector('[data-todo-new-thread-picker]').addEventListener('change', (event) => {
      selectedThread = projectThreads.find((thread) => thread.id === event.target.value) || null;
    });
    tagController.bindDraft(page);
  }

  return { bind, updateProjects, refreshThreadOptions };
}
