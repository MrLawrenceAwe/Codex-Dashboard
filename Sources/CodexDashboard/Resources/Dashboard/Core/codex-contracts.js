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

  function sidePanelToggle() {
    return [...document.querySelectorAll('button[aria-label="Toggle side panel"]')]
      .filter(isVisible)
      .sort((left, right) => right.getBoundingClientRect().left - left.getBoundingClientRect().left)[0]
      || null;
  }

  function environmentToggle() {
    return [...document.querySelectorAll('button[aria-expanded]')].find((button) => (
      isVisible(button) && button.textContent.trim() === 'Environment'
    )) || null;
  }

  function commitOrPushButton() {
    return [...document.querySelectorAll('button[data-slot="thread-summary-panel-item-button"]')]
      .find((button) => (
        isVisible(button)
          && !button.disabled
          && button.textContent.trim() === 'Commit or push'
      )) || null;
  }

  async function probeCommitOrPushControls(timeout = 3000) {
    const waitFor = async (value) => {
      const deadline = performance.now() + timeout;
      while (performance.now() < deadline) {
        const result = value();
        if (result) return result;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      return null;
    };

    if (commitOrPushButton()) return true;

    let openedSidePanel = false;
    let expandedEnvironment = false;
    try {
      let environment = environmentToggle();
      if (!environment) {
        const panelToggle = sidePanelToggle();
        if (!panelToggle) return false;
        panelToggle.click();
        openedSidePanel = true;
        await waitFor(() => commitOrPushButton() || environmentToggle());
      }

      if (commitOrPushButton()) return true;
      environment = environmentToggle();
      if (!environment) return false;
      if (environment.getAttribute('aria-expanded') !== 'true') {
        environment.click();
        expandedEnvironment = true;
      }
      return Boolean(await waitFor(() => commitOrPushButton()));
    } finally {
      if (expandedEnvironment) {
        const environment = environmentToggle();
        if (environment?.getAttribute('aria-expanded') === 'true') environment.click();
      }
      if (openedSidePanel) {
        await new Promise((resolve) => setTimeout(resolve, 50));
        sidePanelToggle()?.click();
      }
    }
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
    composerEditorView,
    sidePanelToggle,
    environmentToggle,
    commitOrPushButton,
    probeCommitOrPushControls,
  };
})();
