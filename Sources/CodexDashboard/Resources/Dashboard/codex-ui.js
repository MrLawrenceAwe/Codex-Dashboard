const codexUI = {
  sidebar() {
    return document.querySelector('aside.app-shell-left-panel, aside');
  },

  pageHost() {
    return this.sidebar()?.parentElement || document.body;
  },

  navigationInsertionPoint() {
    const navigation = document.querySelector('nav, [role="navigation"]');
    if (!navigation) return null;
    const buttons = [...navigation.querySelectorAll('button')];
    const newChat = buttons.find((button) => button.textContent.trim() === 'New chat');
    const newChatRow = newChat?.closest('.sidebar-item');
    if (newChatRow?.parentElement) return { element: newChatRow, insertAfter: true };
    const fallbackButton = buttons.find((button) => button.textContent.trim() === 'Pull requests')
      || buttons.find((button) => button.classList.contains('sidebar-item'));
    return fallbackButton?.parentElement ? { element: fallbackButton, insertAfter: false } : null;
  },

  unreadThreadIDs() {
    const unreadIDs = new Set();
    document.querySelectorAll('[data-app-action-sidebar-thread-id]').forEach((row) => {
      const fiberKey = Object.keys(row).find((key) => key.startsWith('__reactFiber$'));
      let fiber = fiberKey ? row[fiberKey] : null;
      while (fiber) {
        const props = fiber.memoizedProps || fiber.pendingProps;
        if (
          typeof props?.conversationId === 'string'
          && typeof props?.isUnread === 'boolean'
        ) {
          if (props.isUnread) unreadIDs.add(props.conversationId);
          break;
        }
        fiber = fiber.return;
      }
    });
    return unreadIDs;
  },

  navigateToThread(thread) {
    const threadKey = `local:${thread.id}`;
    const sidebarThreadButton = document.querySelector(
      `[data-app-action-sidebar-thread-id="${CSS.escape(threadKey)}"]`,
    );
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

