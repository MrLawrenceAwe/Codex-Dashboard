function createTodoComposerActions({ isDestroyed, pageState, threadReferencesForProject, getItems }) {
  const activeComposer = () => codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
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

  function chooseTodoThread(item, row) {
    if (isDestroyed() || transferring || !item?.project) return;
    const select = row.querySelector('[data-todo-paste-thread]');
    const button = row.querySelector('[data-todo-paste-in-thread]');
    if (!select.hidden) {
      select.hidden = true;
      button.setAttribute('aria-expanded', 'false');
      return;
    }
    const threads = threadsForTodo(item);
    select.replaceChildren(
      new Option(threads.length ? 'Choose a chat to paste into…' : 'No chats in this project', ''),
      ...threads.map((thread) => new Option(`${thread.title}${thread.id === item.thread?.id ? ' (linked chat)' : ''}`, thread.id)),
    );
    select.disabled = threads.length === 0;
    select.hidden = false;
    button.setAttribute('aria-expanded', 'true');
    select.onkeydown = (event) => {
      if (event.key !== 'Escape') return;
      select.hidden = true;
      button.setAttribute('aria-expanded', 'false');
      button.focus();
    };
    select.onchange = () => {
      if (!select.value) return;
      const currentItem = getItems().find((candidate) => candidate.id === item.id);
      const thread = currentItem?.project?.id === item.project.id && !currentItem.completed
        ? threadsForTodo(currentItem).find((candidate) => candidate.id === select.value)
        : null;
      select.hidden = true;
      button.setAttribute('aria-expanded', 'false');
      if (!thread || isDestroyed()) {
        if (!isDestroyed()) showTransferError('This chat is no longer available in the to-do’s project. Choose a chat again.');
        return;
      }
      void pasteTodoInThread(currentItem, thread);
    };
    if (!select.disabled) select.focus();
  }

  function showComposerWarning(composer, message) {
    document.querySelector('[data-todo-preset-warning]')?.remove();
    const notice = document.createElement('div');
    notice.dataset.todoPresetWarning = '';
    notice.setAttribute('role', 'alert');
    notice.textContent = message;
    (composer?.closest('form') || composer?.parentElement || document.body).append(notice);
  }

  async function insertTodoIntoComposer(item, { failurePolicy = 'returnToTodos', waitForStableComposer = false, threadID = null, newProjectID = null } = {}) {
    const isDestination = () => !isDestroyed()
      && (!threadID || codexUIContracts.activeComposerThreadID() === threadID)
      && (!newProjectID || (!codexUIContracts.activeComposerThreadID()
        && codexUIContracts.activeComposerProjectID() === newProjectID));
    const destinationComposer = () => isDestination() ? activeComposer() : null;
    if (isDestroyed()) return false;
    document.querySelector('[data-todo-preset-warning]')?.remove();
    const [loadedItem] = await todoImageStore.load([item]);
    if (isDestroyed()) return false;
    let observedComposer = null;
    let observedAt = 0;
    const composer = await domUtils.waitFor(
      () => {
        if (isDestroyed()) return null;
        const current = destinationComposer();
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
    if (!composer || !isDestination()) {
      if (!isDestroyed()) {
        if (failurePolicy === 'stayInChat') {
          showComposerWarning(activeComposer(), 'Could not find the new chat editor. Return to To-dos and try again.');
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
      if (!await composerModelPicker.applyPreset(item.preset, { isCurrent: isDestination })) {
        if (failurePolicy === 'stayInChat') {
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
    if (!isDestination()) return false;
    const notice = document.querySelector('[data-todo-composer-error]');
    if (notice) notice.hidden = true;
    const content = [item.title, item.body].filter(Boolean).join('\n\n');
    const image = loadedItem?.image;
    const containsText = (editor) => {
      const text = editor?.value ?? editor?.textContent ?? '';
      return text.includes(item.title) && (!item.body || text.includes(item.body));
    };
    const reportTransferFailure = () => {
      if (failurePolicy === 'stayInChat' && activeComposer()) showComposerWarning(
        activeComposer(),
        'Could not insert this to-do in the new chat. Return to To-dos and try again.',
      );
    };
    let imageComposer = null;
    for (let attempt = 0; attempt < 3 && !isDestroyed(); attempt += 1) {
      if (!isDestination()) return false;
      const editor = destinationComposer();
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
      if (!isDestination()) return false;
      const current = destinationComposer();
      if (current && containsText(current) && (!image || current === imageComposer)) {
        if (presetFailed) showComposerWarning(
          current,
          'Could not apply this to-do’s model settings. Check the model, reasoning effort, and speed before sending.',
        );
        return true;
      }
    }
    reportTransferFailure();
    return false;
  }

  async function openTodoInNewThread(item) {
    if (isDestroyed() || transferring || !item?.project) return;
    transferring = true;
    try {
      if (!await codexHost.newChat(item.project.id) || isDestroyed()) return;
      pageState.close();
      await insertTodoIntoComposer(item, {
        failurePolicy: 'stayInChat', waitForStableComposer: true, newProjectID: item.project.id,
      });
    } finally {
      transferring = false;
    }
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
        showTransferError('Could not open the selected chat. Choose a chat again.');
        return;
      }
      if (!await insertTodoIntoComposer(item, { waitForStableComposer: true, threadID: thread.id })) {
        if (!isDestroyed()) showTransferError('Could not paste this to-do. Check the chat editor and model settings, then try again.');
      }
    } finally {
      transferring = false;
    }
  }

  return { openTodoInNewThread, chooseTodoThread };
}
