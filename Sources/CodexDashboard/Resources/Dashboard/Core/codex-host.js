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
    // New chat is wrapped in Codex's tooltip trigger. Inserting our rows after
    // its button would make them children of that trigger, causing the New chat
    // ⌘N tooltip to appear when either injected row is hovered.
    const newChatTooltip = newChatRow?.parentElement?.matches('span[data-state].contents')
      ? newChatRow.parentElement
      : null;
    const newChatInsertionRow = newChatTooltip || newChatRow;
    if (newChatInsertionRow?.parentElement) return { element: newChatInsertionRow, insertAfter: true };
    const fallbackButton = buttons.find((button) => button.textContent.trim() === 'Pull requests')
      || buttons.find((button) => button.classList.contains('sidebar-item'));
    return fallbackButton?.parentElement ? { element: fallbackButton, insertAfter: false } : null;
  },

  async newChat(projectID = '') {
    if (projectID && !codexUIContracts.selectProject(projectID)) return false;
    if (projectID) await new Promise((resolve) => setTimeout(resolve, 0));
    const button = [...(this.sidebar()?.querySelectorAll('button') || [])]
      .find((candidate) => candidate.textContent.trim() === 'New chat');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  },

  composerProject(findThread) {
    const selectedProject = codexUIContracts.activeComposerProject();
    if (selectedProject) return selectedProject;
    const thread = findThread(codexUIContracts.activeComposerThreadID());
    const projectPath = String(thread?.projectPath || '').trim();
    if (!projectPath) return null;
    return {
      name: String(thread?.projectName || '').trim() || projectPath.split('/').filter(Boolean).at(-1) || projectPath,
      path: projectPath,
    };
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

  async openCommitOrPush(thread) {
    const waitFor = (value, timeout = 5000) => domUtils.waitFor(value, { timeout });

    this.navigateToThread(thread);
    const selected = await waitFor(() => codexUIContracts.isThreadSelected(thread.id), 5000);
    if (!selected) return { opened: false, reason: 'Codex did not select the project task.' };

    const gitActions = await waitFor(() => codexUIContracts.gitActionsButton());
    if (!gitActions) return { opened: false, reason: 'Codex did not show Git actions for the project task.' };
    gitActions.dispatchEvent(new PointerEvent('pointerdown', {
      bubbles: true, button: 0, pointerType: 'mouse',
    }));
    gitActions.click();

    const menu = await waitFor(() => codexUIContracts.gitActionsMenu());
    if (!menu) return { opened: false, reason: 'Codex did not open the Git actions menu.' };
    const commit = await waitFor(() => codexUIContracts.gitCommitMenuItem(menu));
    if (!commit) return { opened: false, reason: 'Commit is unavailable in Codex’s Git actions menu.' };
    commit.click();
    return { opened: true };
  },
};
