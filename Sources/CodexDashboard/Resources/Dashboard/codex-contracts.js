const codexContracts = (() => {
  const composerSelectors = [
    'textarea[placeholder="Do anything"]',
    '[contenteditable="true"][data-placeholder="Do anything"]',
    '[contenteditable="true"][role="textbox"]',
    'textarea',
    '[contenteditable="true"]',
  ];
  const promptMenuSelector = [
    '[data-composer-overlay-floating-ui]',
    '[role="menu"]',
    '[data-radix-menu-content]',
    '[data-slot="dropdown-menu-content"]',
  ].join(', ');

  function sidebar() {
    return document.querySelector('aside.app-shell-left-panel, aside');
  }

  function navigation() {
    return document.querySelector('nav, [role="navigation"]');
  }

  function threadRows() {
    return [...document.querySelectorAll('[data-app-action-sidebar-thread-id]')];
  }

  function threadRow(threadID) {
    return document.querySelector(
      `[data-app-action-sidebar-thread-id="${CSS.escape(`local:${threadID}`)}"]`,
    );
  }

  function threadReadStates() {
    const readStates = new Map();
    threadRows().forEach((row) => {
      const fiberKey = Object.keys(row).find((key) => key.startsWith('__reactFiber$'));
      let fiber = fiberKey ? row[fiberKey] : null;
      while (fiber) {
        const props = fiber.memoizedProps || fiber.pendingProps;
        if (typeof props?.conversationId === 'string' && typeof props?.isUnread === 'boolean') {
          readStates.set(props.conversationId, props.isUnread);
          break;
        }
        fiber = fiber.return;
      }
    });
    return readStates;
  }

  function composer(promptDialogID = 'codex-dashboard-prompt-dialog') {
    return composerSelectors.flatMap((selector) => [...document.querySelectorAll(selector)])
      .find((element) => (
        !element.closest(`#${promptDialogID}`) && element.getClientRects().length > 0
      ));
  }

  function promptMenuIsOpen() {
    return [...document.querySelectorAll(promptMenuSelector)].some((menu) => (
      menu.textContent.includes('Work in a project') && menu.textContent.includes('Plan mode')
    ));
  }

  function promptMenuAnchor() {
    const interactiveLabel = [...document.querySelectorAll('button, [role="menuitem"]')]
      .find((element) => element.textContent?.trim() === 'Record a skill');
    const exactLabels = [...document.querySelectorAll('span, div')]
      .filter((element) => element.textContent?.trim() === 'Record a skill');
    const label = interactiveLabel || exactLabels.at(-1);
    if (!label) return null;
    const menu = label.closest(promptMenuSelector)
      || [...function* ancestors() {
        let current = label.parentElement;
        while (current && current !== document.body) {
          yield current;
          current = current.parentElement;
        }
      }()].find((element) => (
        element.textContent.includes('Work in a project')
          && element.textContent.includes('Plan mode')
      ));
    if (!menu || menu.closest('#codex-dashboard-prompt-dialog')) return null;
    let row = label.closest('button, [role="menuitem"]');
    if (!row) {
      row = label;
      while (row.parentElement !== menu && row.parentElement) {
        const parent = row.parentElement;
        if (parent.textContent.trim() !== 'Record a skill') break;
        row = parent;
      }
    }
    return row?.parentElement ? row : null;
  }

  return {
    sidebar,
    navigation,
    threadRows,
    threadRow,
    threadReadStates,
    composer,
    promptMenuIsOpen,
    promptMenuAnchor,
  };
})();
