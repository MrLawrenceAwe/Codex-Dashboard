const codexHost = {
  sidebar() {
    return codexUIContracts.sidebar();
  },

  pageHost() {
    return this.sidebar()?.parentElement || document.body;
  },

  navigationInsertionPoint() {
    const navigation = codexUIContracts.navigation();
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
    return codexUIContracts.threadReadStates();
  },

  navigateToThread(thread) {
    const sidebarThreadButton = codexUIContracts.threadRow(thread.id);
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
    return Boolean(codexUIContracts.commitOrPushButton() || codexUIContracts.sidePanelToggle());
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
    const selected = await waitFor(() => codexUIContracts.isThreadSelected(thread.id), 5000);
    if (!selected) return false;
    await new Promise((resolve) => setTimeout(resolve, 100));

    let commitButton = codexUIContracts.commitOrPushButton();
    if (!commitButton) {
      const sidePanelToggle = codexUIContracts.sidePanelToggle();
      if (!sidePanelToggle) return false;
      sidePanelToggle.click();

      const panelControl = await waitFor(() => (
        codexUIContracts.commitOrPushButton() || codexUIContracts.environmentToggle()
      ));
      if (!panelControl) return false;

      commitButton = codexUIContracts.commitOrPushButton();
      if (!commitButton) {
        if (panelControl.getAttribute('aria-expanded') !== 'true') panelControl.click();
        commitButton = await waitFor(() => codexUIContracts.commitOrPushButton());
      }
    }
    if (!commitButton) return false;
    commitButton.click();
    return true;
  },
};
