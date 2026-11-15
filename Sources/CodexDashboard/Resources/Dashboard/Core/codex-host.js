const codexHost = {
  projectChatButton: null,

  globalNewChatButton() {
    return [...(codexUIContracts.navigation()?.querySelectorAll('button') || [])]
      .find((button) => button.textContent.trim() === 'New chat'
        && !codexUIContracts.sidebarProjects.containingRow(button)
        && !button.closest(codexUIContracts.sidebarThreads.selector)) || null;
  },

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
    let newChatRow = newChat?.closest('.sidebar-item');
    // The main button and its full-width action row both carry sidebar-item.
    // Insert after the outer row so our entries are not clipped beside Quick chat.
    while (newChatRow?.parentElement?.closest('.sidebar-item')
      && navigation.contains(newChatRow.parentElement.closest('.sidebar-item'))) {
      newChatRow = newChatRow.parentElement.closest('.sidebar-item');
    }
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

  async newChat(projectID = null) {
    if (!projectID) {
      // Codex's projectless action explicitly clears the active project.
      window.dispatchEvent(new MessageEvent('message', {
        data: { type: 'new-projectless-task' },
        source: null,
      }));
      return true;
    }
    if (!codexUIContracts.selectProject(projectID)) return false;
    await new Promise((resolve) => setTimeout(resolve, 0));
    const button = this.globalNewChatButton();
    if (!button || button.disabled) return false;
    // Project to-dos intentionally use the host action after selecting a project.
    // Exempt only this synchronous click from the global-button redirect.
    this.projectChatButton = button;
    try {
      button.click();
    } finally {
      this.projectChatButton = null;
    }
    return true;
  },

  composerProject(findThread) {
    const selectedProject = codexUIContracts.activeComposerProject();
    if (selectedProject) return selectedProject;
    const thread = findThread(codexUIContracts.activeComposerThreadID());
    const projectPath = String(thread?.checkoutPath || '').trim();
    if (!projectPath) return null;
    return {
      name: String(thread?.projectName || '').trim() || projectPath.split('/').filter(Boolean).at(-1) || projectPath,
      path: projectPath,
    };
  },

  threadUnreadStates() {
    return codexUIContracts.threadUnreadStates();
  },

  markThreadsRead(threadIDs) {
    return codexUIContracts.markThreadsRead(threadIDs);
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

};
