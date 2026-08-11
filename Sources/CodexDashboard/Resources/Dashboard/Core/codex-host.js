const codexHost = {
  sidebar() {
    return codexContracts.sidebar();
  },

  pageHost() {
    return this.sidebar()?.parentElement || document.body;
  },

  navigationInsertionPoint() {
    const navigation = codexContracts.navigation();
    if (!navigation) return null;
    const buttons = [...navigation.querySelectorAll('button')];
    const newChat = buttons.find((button) => button.textContent.trim() === 'New chat');
    const newChatRow = newChat?.closest('.sidebar-item');
    if (newChatRow?.parentElement) return { element: newChatRow, insertAfter: true };
    const fallbackButton = buttons.find((button) => button.textContent.trim() === 'Pull requests')
      || buttons.find((button) => button.classList.contains('sidebar-item'));
    return fallbackButton?.parentElement ? { element: fallbackButton, insertAfter: false } : null;
  },

  threadReadStates() {
    return codexContracts.threadReadStates();
  },

  navigateToThread(thread) {
    const sidebarThreadButton = codexContracts.threadRow(thread.id);
    if (sidebarThreadButton) {
      sidebarThreadButton.click();
      return;
    }
    window.dispatchEvent(new MessageEvent('message', {
      data: {
        type: 'navigate-to-route',
        path: `/local/${encodeURIComponent(thread.id)}`,
      },
      source: null,
    }));
  },

  async canOpenCommitOrPush() {
    return codexContracts.canDispatchCommand();
  },

  async openCommitOrPush(thread) {
    const waitFor = async (value, timeout = 3000) => {
      const deadline = performance.now() + timeout;
      while (performance.now() < deadline) {
        const result = value();
        if (result) return result;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      return null;
    };

    this.navigateToThread(thread);
    const selected = await waitFor(() => codexContracts.isThreadSelected(thread.id), 5000);
    if (!selected) return false;
    await new Promise((resolve) => setTimeout(resolve, 100));

    return codexContracts.dispatchCommand('git.commit');
  },
};
