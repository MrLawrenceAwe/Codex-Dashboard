const codexUIContracts = (() => {
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

  const { isVisible } = domUtils;

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

  function activeComposerProject() {
    const activeComposer = composer();
    let host = activeComposer?.parentElement;
    let projectID;
    while (host && host !== document.body && !projectID) {
      const fiberKey = Object.keys(host).find((key) => key.startsWith('__reactFiber$'));
      let fiber = fiberKey ? host[fiberKey] : null;
      while (fiber) {
        const props = fiber.memoizedProps || fiber.pendingProps;
        const selectedProject = props?.selectedProject;
        if (
          selectedProject?.type === 'local'
            && typeof selectedProject.projectId === 'string'
            && selectedProject.projectId.trim()
        ) {
          projectID = selectedProject.projectId.trim();
          break;
        }
        fiber = fiber.return;
      }
      host = host.parentElement;
    }
    if (!projectID) return null;

    const projectRow = document.querySelector(
      `[data-app-action-sidebar-project-id="${CSS.escape(projectID)}"]`,
    );
    const fiberKey = projectRow
      && Object.keys(projectRow).find((key) => key.startsWith('__reactFiber$'));
    let fiber = fiberKey ? projectRow[fiberKey] : null;
    while (fiber) {
      const props = fiber.memoizedProps || fiber.pendingProps;
      const group = props?.group;
      const path = String(group?.path || '').trim();
      if (group?.projectId === projectID && group?.projectKind === 'local' && path) {
        return {
          name: String(group.label || '').trim()
            || path.split('/').filter(Boolean).at(-1)
            || path,
          path,
        };
      }
      fiber = fiber.return;
    }
    return null;
  }

  // DOM nodes retain their original fiber across React's alternating commits.
  // Follow committed parent child-lists, including shared bailout subtrees.
  function committedFiber(fiber, cache) {
    if (!fiber) return null;
    if (cache.has(fiber)) return cache.get(fiber);
    let current = null;
    if (!fiber.return) {
      current = fiber.stateNode?.current || (fiber.alternate ? null : fiber);
    } else {
      const parent = committedFiber(fiber.return, cache);
      let child = parent?.child;
      while (child) {
        if (child === fiber || child === fiber.alternate) {
          current = child;
          break;
        }
        child = child.sibling;
      }
    }
    cache.set(fiber, current);
    if (fiber.alternate) cache.set(fiber.alternate, current);
    return current;
  }

  function threadReadStates() {
    const readStates = new Map();
    const fiberCache = new Map();
    threadRows().forEach((row) => {
      const sidebarID = row.getAttribute('data-app-action-sidebar-thread-id') || '';
      if (!sidebarID.startsWith('local:')) return;
      const threadID = sidebarID.slice('local:'.length);
      if (!threadID) return;
      const fiberKey = Object.keys(row).find((key) => key.startsWith('__reactFiber$'));
      let fiber = committedFiber(fiberKey ? row[fiberKey] : null, fiberCache);
      while (fiber) {
        const props = fiber.memoizedProps;
        if (props?.conversationId === threadID && typeof props?.isUnread === 'boolean') {
          readStates.set(props.conversationId, props.isUnread);
          break;
        }
        fiber = committedFiber(fiber.return, fiberCache);
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

  function intelligenceTrigger(promptDialogID = 'codex-dashboard-prompt-library-dialog') {
    const activeComposer = composer(promptDialogID);
    let container = activeComposer?.parentElement;
    while (container && container !== document.body) {
      const trigger = [...container.querySelectorAll('[data-codex-intelligence-trigger]')]
        .find(isVisible);
      if (trigger) return trigger;
      container = container.parentElement;
    }
    return [...document.querySelectorAll('[data-codex-intelligence-trigger]')].find(isVisible) || null;
  }

  function modelPicker() {
    return [...document.querySelectorAll('[data-model-picker-view]')].find(isVisible) || null;
  }

  async function probeModelPickerControls(timeout = 1200) {
    const trigger = intelligenceTrigger();
    if (!trigger) return false;
    const waitFor = (value) => domUtils.waitFor(value, { timeout, interval: 25 });
    const wasExpanded = trigger.getAttribute('aria-expanded') === 'true';
    try {
      if (!wasExpanded) {
        trigger.dispatchEvent(new PointerEvent('pointerdown', {
          bubbles: true, button: 0, pointerType: 'mouse',
        }));
        trigger.click();
      }
      const picker = await waitFor(modelPicker);
      if (!picker) return false;
      const effort = trigger.dataset.selectedReasoningEffort;
      const hasSupportedEffort = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].includes(effort);
      return hasSupportedEffort
        && Boolean(picker.querySelector('[data-model-picker-view-toggle]'))
        && Boolean(picker.querySelector('[data-reasoning-slider]'));
    } finally {
      if (!wasExpanded && trigger.getAttribute('aria-expanded') === 'true') {
        document.body.click();
      }
    }
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

  return {
    sidebar,
    navigation,
    threadRows,
    threadRow,
    isThreadSelected,
    activeComposerThreadID,
    activeComposerProject,
    threadReadStates,
    composer,
    composerAddButton,
    composerEditorView,
    intelligenceTrigger,
    modelPicker,
    probeModelPickerControls,
    sidePanelToggle,
    environmentToggle,
    commitOrPushButton,
  };
})();
