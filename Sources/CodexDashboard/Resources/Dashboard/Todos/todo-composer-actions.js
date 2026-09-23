function createTodoComposerActions({ isDestroyed, pageState }) {
  async function insertTodoIntoComposer(item) {
    if (isDestroyed()) return false;
    const [loadedItem] = await todoStore.loadImages([item]);
    if (isDestroyed()) return false;
    if (item.preset) {
      const composer = await domUtils.waitFor(
        () => isDestroyed() || codexUIContracts.composer(dashboardElements.elementIDs.promptDialog),
        { timeout: 3000, interval: 25 },
      );
      if (!composer || isDestroyed() || !await composerModelPicker.applyPreset(item.preset)) {
        if (!isDestroyed()) {
          pageState.open();
          const notice = document.querySelector('[data-todo-composer-error]');
          if (notice) notice.hidden = false;
        }
        return false;
      }
    }
    const notice = document.querySelector('[data-todo-composer-error]');
    if (notice) notice.hidden = true;
    const content = [item.title, item.body].filter(Boolean).join('\n\n');
    const image = loadedItem?.image;
    let inserted = false;
    const transfer = () => {
      if (isDestroyed()) return false;
      if (!inserted) inserted = composerAdapter.insert(content);
      return inserted && (!image || composerAdapter.attachImage(image));
    };
    if (transfer()) return true;
    const composer = await domUtils.waitFor(
      () => isDestroyed() || codexUIContracts.composer(dashboardElements.elementIDs.promptDialog),
      { timeout: 3000, interval: 25 },
    );
    return Boolean(composer && !isDestroyed() && transfer());
  }

  async function openTodoInNewThread(item) {
    if (isDestroyed() || !item?.project || !await codexHost.newChat(item.project.id) || isDestroyed()) return;
    pageState.close();
    await insertTodoIntoComposer(item);
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
