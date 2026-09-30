function bindTodoItemInteractions(page, { getItems, updateItem, commitItems, composerActions, draftPreset, render, setExpandedPresetTodoID }) {
  function bindItemEditing(page) {
    page.querySelector('[data-todo-list]').addEventListener('click', (event) => {
      if (event.target.matches('[data-todo-preset-details] > summary')) {
        setExpandedPresetTodoID(event.target.closest('[data-todo-preset-details]').open
          ? null : event.target.closest('[data-todo-id]').dataset.todoId);
      }
    });
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
        const currentProjectID = getItems().find((item) => item.id === row.dataset.todoId)?.project?.id;
        const changes = { project };
        if (currentProjectID !== project?.id) changes.thread = null;
        void updateItem(row.dataset.todoId, changes);
      } else if (event.target.matches('[data-todo-preset-enabled], [data-todo-item-preset-model], [data-todo-item-preset-effort], [data-todo-item-preset-speed]')) {
        const preset = draftPreset(
          row.querySelector('[data-todo-preset-enabled]'),
          row.querySelector('[data-todo-item-preset-fields]'),
        );
        setExpandedPresetTodoID(row.dataset.todoId);
        void updateItem(row.dataset.todoId, { preset });
      } else if (event.target.matches('[data-todo-tag]')) {
        const item = getItems().find((candidate) => candidate.id === row.dataset.todoId);
        if (item && event.target.value) void updateItem(item.id, {
          tags: todoStore.normalizeTags([...item.tags, event.target.value]),
        });
      }
    });
  }

  function bindItemActions(page) {
    page.querySelector('[data-todo-list]').addEventListener('click', (event) => {
      const row = event.target.closest('[data-todo-id]');
      const item = row && getItems().find((candidate) => candidate.id === row.dataset.todoId);
      const previewButton = event.target.closest('[data-todo-image-preview]');
      if (previewButton) {
        if (item?.image) todoListView.showImage(item.image);
        return;
      }
      const newThreadButton = event.target.closest('[data-todo-new-thread]');
      if (newThreadButton) {
        void composerActions.openTodoInNewThread(item);
        return;
      }
      const pasteInThreadButton = event.target.closest('[data-todo-paste-in-thread]');
      if (pasteInThreadButton) {
        composerActions.chooseTodoThread(item);
        return;
      }
      const removeImageButton = event.target.closest('[data-todo-image-remove]');
      if (removeImageButton) {
        if (row) void updateItem(row.dataset.todoId, { image: null });
        return;
      }
      const removeTagButton = event.target.closest('[data-todo-tag-remove]');
      if (removeTagButton) {
        if (item) void updateItem(item.id, {
          tags: item.tags.filter((tag) => tag !== removeTagButton.dataset.todoTagRemove),
        });
        return;
      }
      const button = event.target.closest('[data-todo-delete]');
      if (!button) return;
      if (!row) return;
      if (!button.dataset.todoDeleteConfirm) {
        button.dataset.todoDeleteConfirm = row.dataset.todoId;
        button.textContent = 'Confirm delete';
        button.setAttribute('aria-label', 'Confirm to-do deletion');
        button.title = 'Confirm delete to-do';
        return;
      }
      void commitItems(getItems().filter((item) => item.id !== row.dataset.todoId));
    });
  }

  bindItemEditing(page);
  bindItemActions(page);
}
