function createTodoComposerActions({ isDestroyed, pageState }) {
  const activeComposer = () => codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);

  function showComposerWarning(composer, message) {
    document.querySelector('[data-todo-preset-warning]')?.remove();
    const notice = document.createElement('div');
    notice.dataset.todoPresetWarning = '';
    notice.setAttribute('role', 'alert');
    notice.textContent = message;
    (composer?.closest('form') || composer?.parentElement || document.body).append(notice);
  }

  async function insertTodoIntoComposer(item, { keepDraftOnPresetFailure = false, waitForNavigation = false } = {}) {
    if (isDestroyed()) return false;
    document.querySelector('[data-todo-preset-warning]')?.remove();
    const [loadedItem] = await todoStore.loadImages([item]);
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
        if (!waitForNavigation) return current;
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
          'Could not apply this to-do’s model preset. Check the model, effort, and speed before sending.',
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
    await insertTodoIntoComposer(item, { keepDraftOnPresetFailure: true, waitForNavigation: true });
  }

  async function pasteTodoInThread(item) {
    if (isDestroyed() || !item?.thread) return;
    pageState.close();
    codexHost.navigateToThread(item.thread);
    const selected = await domUtils.waitFor(
      () => isDestroyed() || codexUIContracts.isThreadSelected(item.thread.id),
      { timeout: 5000, interval: 25 },
    );
    if (selected && !isDestroyed()) await insertTodoIntoComposer(item);
  }

  return { openTodoInNewThread, pasteTodoInThread };
}
