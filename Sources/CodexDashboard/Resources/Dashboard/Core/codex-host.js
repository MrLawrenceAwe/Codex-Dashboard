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
      // The sidebar New chat button can retain the current project.
      window.dispatchEvent(new MessageEvent('message', {
        data: { type: 'new-projectless-task' },
        source: null,
      }));
      return true;
    }
    if (!codexUIContracts.selectProject(projectID)) return false;
    await new Promise((resolve) => setTimeout(resolve, 0));
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

  async openCommitDialog(thread) {
    const waitFor = (value, timeout = 5000) => domUtils.waitFor(value, { timeout });
    const isSelected = () => {
      const composerThreadID = codexUIContracts.activeComposerThreadID();
      return composerThreadID
        ? composerThreadID === thread.id
        : codexUIContracts.isThreadSelected(thread.id);
    };
    this.navigateToThread(thread);
    const selected = await waitFor(isSelected);
    if (!selected) return { opened: false, reason: 'Codex did not select the project chat.' };

    const cancelled = { opened: false, cancelled: true, reason: 'The selected chat changed. Git handoff cancelled.' };
    const waitForSelected = (value) => waitFor(() => !isSelected() ? cancelled : value());
    const action = thread.projectGitStatus === 'unpushedCommits' ? 'Push' : 'Commit';
    const gitActions = await waitForSelected(() => codexUIContracts.gitActionsButton());
    if (gitActions === cancelled || !isSelected()) return cancelled;
    if (!gitActions) return { opened: false, reason: 'Codex did not show Git actions for the project chat.' };
    if (gitActions.getAttribute('aria-expanded') !== 'true') {
      gitActions.dispatchEvent(new PointerEvent('pointerdown', {
        bubbles: true, button: 0, pointerType: 'mouse',
      }));
      if (!isSelected()) return cancelled;
      gitActions.click();
    }

    const menu = await waitForSelected(() => codexUIContracts.gitActionsMenu(gitActions));
    if (menu === cancelled || !isSelected()) return cancelled;
    if (!menu) return { opened: false, reason: 'Codex did not open the Git actions menu.' };
    const item = await waitForSelected(() => {
      const currentMenu = codexUIContracts.gitActionsMenu(gitActions);
      return currentMenu && codexUIContracts.gitActionMenuItem(currentMenu, action);
    });
    if (item === cancelled || !isSelected()) return cancelled;
    if (!item) return { opened: false, reason: `${action} is unavailable in Codex’s Git actions menu.` };
    item.click();
    return { opened: true };
  },
};
