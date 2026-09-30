function createTodoComposerActions({ isDestroyed, pageState, threadReferencesForProject, getItems }) {
  const activeComposer = () => codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
  let pickerDialog;
  let transferring = false;

  function threadsForTodo(item) {
    const project = codexUIContracts.projects().find((candidate) => candidate.id === item.project?.id);
    return project ? threadReferencesForProject(project) : [];
  }

  function showTransferError(message) {
    pageState.open();
    const notice = document.querySelector('[data-todo-composer-error]');
    if (notice) {
      notice.textContent = message;
      notice.hidden = false;
    }
  }

  function chooseTodoThread(item) {
    if (isDestroyed() || transferring || !item?.project) return;
    const dialog = todoListView.ensureDialogHost().querySelector('[data-todo-thread-dialog]');
    if (dialog.open) return;
    pickerDialog = dialog;
    const select = dialog.querySelector('[data-todo-paste-thread]');
    const submit = dialog.querySelector('[data-todo-thread-confirm]');
    const threads = threadsForTodo(item);
    dialog.querySelector('[data-todo-thread-project]').textContent = `Choose a chat/task in ${item.project.name}.`;
    select.replaceChildren(new Option('Choose a chat/task…', ''), ...threads.map((thread) => new Option(thread.title, thread.id)));
    select.value = threads.some((thread) => thread.id === item.thread?.id) ? item.thread.id : '';
    select.disabled = threads.length === 0;
    submit.disabled = !select.value;
    dialog.querySelector('[data-todo-thread-empty]').hidden = threads.length > 0;
    select.onchange = () => { submit.disabled = !select.value; };
    const close = () => dialog.close();
    dialog.querySelector('[data-todo-thread-dialog-close]').onclick = close;
    dialog.querySelector('[data-todo-thread-cancel]').onclick = close;
    dialog.onclick = (event) => { if (event.target === dialog) close(); };
    dialog.querySelector('[data-todo-thread-form]').onsubmit = (event) => {
      event.preventDefault();
      const currentItem = getItems().find((candidate) => candidate.id === item.id);
      const thread = currentItem?.project?.id === item.project.id && !currentItem.completed
        ? threadsForTodo(currentItem).find((candidate) => candidate.id === select.value)
        : null;
      close();
      if (!thread || isDestroyed()) {
        if (!isDestroyed()) showTransferError('This chat/task is no longer available in the to-do’s project. Choose a chat/task again.');
        return;
      }
      void pasteTodoInThread(currentItem, thread);
    };
    dialog.showModal();
  }

  function showComposerWarning(composer, message) {
    document.querySelector('[data-todo-preset-warning]')?.remove();
    const notice = document.createElement('div');
    notice.dataset.todoPresetWarning = '';
    notice.setAttribute('role', 'alert');
    notice.textContent = message;
    (composer?.closest('form') || composer?.parentElement || document.body).append(notice);
  }

  async function insertTodoIntoComposer(item, { keepDraftOnPresetFailure = false, waitForStableComposer = false } = {}) {
    if (isDestroyed()) return false;
    document.querySelector('[data-todo-preset-warning]')?.remove();
    const [loadedItem] = await todoImageStore.load([item]);
    if (isDestroyed()) return false;
    let observedComposer = null;
    let observedAt = 0;
    const composer = await domUtils.waitFor(
      () => {
        if (isDestroyed()) return null;
        const current = activeComposer();
        if (!current) {
          observedComposer = null;
          return null;
        }
        if (!waitForStableComposer) return current;
        // Codex can reuse the new-task editor when the project stays the same.
        // Wait for a stable editor, whether navigation reused or replaced it.
        if (current !== observedComposer) {
          observedComposer = current;
          observedAt = performance.now();
        }
        return performance.now() - observedAt >= 500 ? current : null;
      },
      { timeout: 5000, interval: 25 },
    );
    if (!composer || isDestroyed()) {
      if (!isDestroyed()) {
        if (keepDraftOnPresetFailure) {
          showComposerWarning(activeComposer(), 'Could not find the new task editor. Return to To-dos and try again.');
        } else {
          pageState.open();
          const notice = document.querySelector('[data-todo-composer-error]');
          if (notice) notice.hidden = false;
        }
      }
      return false;
    }
    let presetFailed = false;
    if (item.preset) {
      if (!await composerModelPicker.applyPreset(item.preset)) {
        if (keepDraftOnPresetFailure) {
          presetFailed = true;
        } else {
          if (!isDestroyed()) {
            pageState.open();
            const notice = document.querySelector('[data-todo-composer-error]');
            if (notice) notice.hidden = false;
          }
          return false;
        }
      }
    }
    const notice = document.querySelector('[data-todo-composer-error]');
    if (notice) notice.hidden = true;
    const content = [item.title, item.body].filter(Boolean).join('\n\n');
    const image = loadedItem?.image;
    const containsText = (editor) => {
      const text = editor?.value ?? editor?.textContent ?? '';
      return text.includes(item.title) && (!item.body || text.includes(item.body));
    };
    const reportTransferFailure = () => {
      if (keepDraftOnPresetFailure && activeComposer()) showComposerWarning(
        activeComposer(),
        'Could not insert this to-do in the new task. Return to To-dos and try again.',
      );
    };
    let imageComposer = null;
    for (let attempt = 0; attempt < 3 && !isDestroyed(); attempt += 1) {
      const editor = activeComposer();
      if (!editor) {
        await domUtils.delay(100);
        continue;
      }
      if (!containsText(editor) && !composerAdapter.insert(content)) {
        reportTransferFailure();
        return false;
      }
      if (image && imageComposer !== editor) {
        if (!await composerAdapter.attachImage(image)) {
          reportTransferFailure();
          return false;
        }
        imageComposer = editor;
      }
      await domUtils.delay(100);
      const current = activeComposer();
      if (current && containsText(current) && (!image || current === imageComposer)) {
        if (presetFailed) showComposerWarning(
          current,
          'Could not apply this to-do’s composer preset. Check the model, effort, and speed before sending.',
        );
        return true;
      }
    }
    reportTransferFailure();
    return false;
  }

  async function openTodoInNewThread(item) {
    if (isDestroyed() || !item?.project || !await codexHost.newChat(item.project.id) || isDestroyed()) return;
    pageState.close();
    await insertTodoIntoComposer(item, { keepDraftOnPresetFailure: true, waitForStableComposer: true });
  }

  async function pasteTodoInThread(item, thread) {
    if (isDestroyed() || transferring) return;
    transferring = true;
    try {
      pageState.close();
      codexHost.navigateToThread(thread);
      const selected = await domUtils.waitFor(
        () => isDestroyed() || codexUIContracts.isThreadSelected(thread.id),
        { timeout: 5000, interval: 25 },
      );
      if (isDestroyed()) return;
      if (!selected) {
        showTransferError('Could not open the selected chat/task. Choose a chat/task again.');
        return;
      }
      if (!await insertTodoIntoComposer(item, { waitForStableComposer: true })) {
        if (!isDestroyed()) showTransferError('Could not paste this to-do. Check the chat/task editor and composer preset, then try again.');
      }
    } finally {
      transferring = false;
    }
  }

  function destroy() {
    if (pickerDialog?.open) pickerDialog.close();
  }

  return { openTodoInNewThread, chooseTodoThread, destroy };
}
