const codexContracts = (() => {
  const composerSelectors = [
    'textarea[placeholder="Do anything"]',
    '[contenteditable="true"][data-placeholder="Do anything"]',
    '[contenteditable="true"][role="textbox"]',
    'textarea',
    '[contenteditable="true"]',
  ];
  const composerAddButtonSelectors = [
    'button[aria-label="Add"]',
    'button[aria-label^="Add "]',
    'button[aria-label*="attachment" i]',
    'button[data-testid="composer-plus-btn"]',
    'button[data-testid="composer-attachment-button"]',
  ];

  function isVisible(element) {
    if (!element || element.getClientRects().length === 0) return false;
    const style = getComputedStyle(element);
    return style.display !== 'none' && style.visibility !== 'hidden';
  }

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

  function isThreadSelected(threadID) {
    return threadRow(threadID)?.getAttribute('aria-current') === 'page'
      || activeComposerThreadID() === threadID;
  }

  function activeComposerThreadID() {
    const activeComposer = composer();
    let host = activeComposer?.parentElement;
    while (host && host !== document.body) {
      const fiberKey = Object.keys(host).find((key) => key.startsWith('__reactFiber$'));
      let fiber = fiberKey ? host[fiberKey] : null;
      while (fiber) {
        const props = fiber.memoizedProps || fiber.pendingProps;
        if (typeof props?.conversationId === 'string') return props.conversationId;
        fiber = fiber.return;
      }
      host = host.parentElement;
    }
    return null;
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

  function composer(promptDialogID = 'codex-dashboard-prompt-library-dialog') {
    return composerSelectors.flatMap((selector) => [...document.querySelectorAll(selector)])
      .find((element) => (
        !element.closest(`#${promptDialogID}`) && element.getClientRects().length > 0
      ));
  }

  function composerAddButton(promptDialogID = 'codex-dashboard-prompt-library-dialog') {
    const activeComposer = composer(promptDialogID);
    if (!activeComposer) return null;
    const candidates = composerAddButtonSelectors
      .flatMap((selector) => [...document.querySelectorAll(selector)])
      .filter((button) => (
        !button.closest(`#${promptDialogID}`) && button.getClientRects().length > 0
      ));
    let container = activeComposer.parentElement;
    while (container && container !== document.body) {
      const nearbyButton = candidates.find((button) => container.contains(button));
      if (nearbyButton) return nearbyButton;
      container = container.parentElement;
    }
    return null;
  }

  function composerMutationSelector(additionalSelectors = []) {
    return [...composerSelectors, ...composerAddButtonSelectors, ...additionalSelectors].join(',');
  }

  function composerEditorView(composerElement) {
    const host = composerElement?.parentElement;
    const fiberKey = host && Object.keys(host).find((key) => key.startsWith('__reactFiber$'));
    let fiber = fiberKey ? host[fiberKey] : null;
    while (fiber) {
      const props = fiber.pendingProps || fiber.memoizedProps;
      const view = props?.composerController?.view;
      if (
        view?.dom === composerElement
          && typeof view.focus === 'function'
          && typeof view.dispatch === 'function'
          && typeof view.state?.tr?.replaceSelection === 'function'
          && typeof view.state?.schema?.nodes?.paragraph?.create === 'function'
      ) return view;
      fiber = fiber.return;
    }
    return null;
  }

  function commandModuleURL() {
    return document.querySelector(
      'link[rel="modulepreload"][href*="/assets/app-initial-"][href$=".js"]',
    )?.href || null;
  }

  async function commandDispatcher() {
    let dispatcher = window.__codexDashboardCommandDispatcher;
    if (typeof dispatcher !== 'function') {
      const moduleURL = commandModuleURL();
      if (!moduleURL) return null;
      try {
        const appModule = await import(moduleURL);
        dispatcher = Object.values(appModule).find((candidate) => (
          typeof candidate === 'function' && candidate.name === 'xM' && candidate.length === 3
        )) || appModule.k8;
      } catch (_) {
        return null;
      }
    }
    return typeof dispatcher === 'function' ? dispatcher : null;
  }

  async function canDispatchCommand() {
    return Boolean(await commandDispatcher());
  }

  async function dispatchCommand(commandID) {
    const dispatcher = await commandDispatcher();
    return dispatcher?.(commandID, 'codex_dashboard') === true;
  }

  return {
    sidebar,
    navigation,
    threadRows,
    threadRow,
    isThreadSelected,
    activeComposerThreadID,
    threadReadStates,
    composer,
    composerAddButton,
    composerMutationSelector,
    composerEditorView,
    commandModuleURL,
    canDispatchCommand,
    dispatchCommand,
  };
})();
