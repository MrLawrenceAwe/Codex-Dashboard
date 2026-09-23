function createTodoTagController({ isDestroyed, getAvailableTags, getItems, commitChange }) {
  let draft = [];

  function reset() {
    draft = [];
    todoListView?.updateTagDraft?.(draft);
  }

  function add(value) {
    if (!getAvailableTags().includes(value)) return false;
    const tags = todoStore.normalizeTags([...draft, value]);
    if (tags.length === draft.length) return false;
    draft = tags;
    todoListView.updateTagDraft(draft);
    return true;
  }

  async function save(nextTags, transformTag = (tag) => tag) {
    const previousDraft = draft;
    const nextDraft = draft.map(transformTag).filter(Boolean);
    draft = nextDraft;
    todoListView.updateTagDraft(draft);
    const saved = await commitChange(nextTags, transformTag);
    if (!saved && !isDestroyed() && draft === nextDraft) {
      draft = previousDraft;
      todoListView.updateTagDraft(draft);
    }
    return saved;
  }

  function bindDraft(page) {
    const input = page.querySelector('[data-todo-new-tag]');
    const addDraftTag = () => {
      if (!add(input.value)) return;
      input.value = '';
      input.focus();
    };
    input.addEventListener('change', addDraftTag);
    page.querySelector('[data-todo-new-tags]').addEventListener('click', (event) => {
      const button = event.target.closest('[data-todo-tag-remove]');
      if (!button) return;
      draft = draft.filter((tag) => tag !== button.dataset.todoTagRemove);
      todoListView.updateTagDraft(draft);
      input.focus();
    });
  }

  function bindManagement(page) {
    const button = page.querySelector('[data-todo-manage-tags]');
    button.addEventListener('click', () => {
      let dialog = document.querySelector('[data-todo-tag-dialog]');
      if (!dialog) {
        dialog = todoListView.ensureDialogHost().querySelector('[data-todo-tag-dialog]');
        bindDialog(dialog);
        todoListView.updateManagedTags(getAvailableTags(), getItems());
      }
      if (!dialog.open) dialog.showModal();
    });
    bindDialog(document.querySelector('[data-todo-tag-dialog]'));
  }

  function bindDialog(dialog) {
    const input = dialog.querySelector('[data-todo-tag-name]');
    const submit = dialog.querySelector('[data-todo-tag-form] button[type="submit"]');
    const cancel = dialog.querySelector('[data-todo-tag-cancel]');
    const label = dialog.querySelector('.todo-tag-form label');
    const resetForm = () => {
      input.value = '';
      delete input.dataset.todoTagRename;
      input.setAttribute('aria-label', 'Tag name');
      label.textContent = 'Tag name';
      submit.textContent = 'Create tag';
      cancel.hidden = true;
    };
    const close = () => { if (dialog.open) dialog.close(); };
    dialog.querySelector('[data-todo-tag-dialog-close]').addEventListener('click', close);
    dialog.addEventListener('click', (event) => { if (event.target === dialog) close(); });
    dialog.addEventListener('close', resetForm);
    cancel.addEventListener('click', () => { resetForm(); input.focus(); });
    dialog.querySelector('[data-todo-tag-form]').addEventListener('submit', (event) => {
      event.preventDefault();
      const oldTag = input.dataset.todoTagRename;
      const availableTags = getAvailableTags();
      const replacement = todoStore.normalizeTags([input.value])[0];
      if (oldTag && availableTags.some((tag) => tag !== oldTag
        && tag.toLocaleLowerCase() === replacement?.toLocaleLowerCase())) return;
      const nextTags = oldTag
        ? todoStore.normalizeTags(availableTags.map((tag) => tag === oldTag ? input.value : tag))
        : todoStore.normalizeTags([...availableTags, input.value]);
      if (!replacement || (!oldTag && nextTags.length === availableTags.length)
        || (oldTag && nextTags.every((tag, index) => tag === availableTags[index]))) return;
      void save(nextTags, (tag) => tag === oldTag ? replacement : tag);
      resetForm();
      input.focus();
    });
    dialog.querySelector('[data-todo-managed-tags]').addEventListener('click', (event) => {
      const editButton = event.target.closest('[data-todo-managed-tag-edit]');
      if (editButton) {
        input.value = editButton.dataset.todoManagedTagEdit;
        input.dataset.todoTagRename = editButton.dataset.todoManagedTagEdit;
        input.setAttribute('aria-label', `Rename tag ${editButton.dataset.todoManagedTagEdit}`);
        label.textContent = 'Rename tag';
        submit.textContent = 'Save tag';
        cancel.hidden = false;
        input.focus();
        input.select();
        return;
      }
      const button = event.target.closest('[data-todo-managed-tag-remove]');
      if (!button) return;
      const tag = button.dataset.todoManagedTagRemove;
      const nextTags = getAvailableTags().filter((candidate) => candidate !== tag);
      if (nextTags.length === getAvailableTags().length) return;
      if (input.dataset.todoTagRename === tag) resetForm();
      void save(nextTags, (candidate) => candidate === tag ? null : candidate);
    });
  }

  reset();
  return { bindDraft, bindManagement, draft: () => draft, reset };
}
