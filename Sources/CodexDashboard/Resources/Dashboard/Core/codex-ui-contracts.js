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

  function reactFiber(element) {
    if (!element) return null;
    const key = Object.keys(element).find(key => key.startsWith('__reactFiber$'));
    return key ? element[key] : null;
  }

  function* parentFibers(element) {
    for (let fiber = currentFiber(reactFiber(element)); fiber; fiber = fiber.return) yield fiber;
  }

  function currentFiber(fiber) {
    // DOM nodes retain their original fiber while React alternates trees.
    // Follow child membership through shared/bailout parents to the mounted tree.
    if (!fiber?.alternate) return fiber;
    const alternate = fiber.alternate;
    let a = fiber;
    let b = alternate;
    while (a.return) {
      const parentA = a.return;
      const parentB = parentA.alternate;
      if (!parentB) {
        if (!parentA.return) break;
        a = b = parentA.return;
        continue;
      }
      if (parentA.child === parentB.child) {
        for (let child = parentA.child; child; child = child.sibling) {
          if (child === a) return fiber;
          if (child === b) return alternate;
        }
        return fiber;
      }
      if (a.return !== b.return) {
        a = parentA;
        b = parentB;
        continue;
      }
      let found = false;
      for (const parent of [parentA, parentB]) {
        for (let child = parent.child; child; child = child.sibling) {
          if (child !== a && child !== b) continue;
          const same = child === a;
          a = same ? parent : parent.alternate;
          b = same ? parent.alternate : parent;
          found = true;
          break;
        }
        if (found) break;
      }
      if (!found) return fiber;
    }
    return a.stateNode?.current === a ? fiber : alternate;
  }

  // Inspect speech controller props during startup/transcription, before the
  // dictation footer or realtime orb mounts. Avoid translated button labels.
  function hasHostSpeechInput() {
    if (document.querySelector('[data-dictation-view], [data-realtime-voice-orb]')) return true;
    const visited = new Set();
    for (const element of document.querySelectorAll('button, [data-composer-body]')) {
      for (const fiber of parentFibers(element)) {
        if (visited.has(fiber)) break;
        visited.add(fiber);
        const props = fiber.memoizedProps;
        if (!props || typeof props !== 'object') continue;
        if (props.isDictating === true || props.isDictationStarting === true || props.isTranscribing === true) return true;
        if (typeof props.startDictation === 'function' && (props.isStarting === true || props.isPreparing === true)) return true;
        const phase = props.realtimeSession?.thread?.phase;
        if (typeof phase === 'string' && phase !== 'inactive') return true;
      }
    }
    return false;
  }

  function hasActiveSpeechInput() {
    // Focus changes must also respect our own edit session; its guard only checks host speech.
    return hasHostSpeechInput()
      || Boolean(document.querySelector('[data-edit-dictation-state=starting], [data-edit-dictation-state=recording], [data-edit-dictation-state=transcribing]'));
  }

  function sidebar() {
    return document.querySelector('aside.app-shell-left-panel, aside');
  }

  function navigation() {
    // The app rail precedes Home navigation; only the latter owns chat rows.
    const root = sidebar();
    if (!root) return null;
    return root.querySelector('nav:not([data-app-navigation-rail]), [role="navigation"]')
      || (root.matches('[role="navigation"]') ? root : null);
  }

  function visibleAction(label, root = document) {
    return [...root.querySelectorAll('[role="menuitem"], button')].find((element) => (
      (element.textContent.trim() === label || element.textContent.trim().startsWith(label))
        && isVisible(element)
    ));
  }

  function profileMenu() {
    const logout = visibleAction('Log out');
    const settings = visibleAction('Settings');
    if (!logout || !settings) return null;
    const semanticMenu = logout.closest('[role="menu"]');
    if (semanticMenu) return semanticMenu;
    const sharedParent = logout.parentElement?.parentElement;
    return sharedParent && sharedParent.contains(settings) ? sharedParent : logout.parentElement;
  }

  function profileMenuTrigger() {
    return [...document.querySelectorAll('button[aria-haspopup="menu"]')].find((button) => (
      isVisible(button) && button.getAttribute('aria-label') === 'Open profile menu'
    )) || null;
  }

  function profileMenuAccountAnchor(menu) {
    return menu ? visibleAction('Settings', menu) || null : null;
  }

  const threadIDAttribute = 'data-app-action-sidebar-thread-id';
  const threadTitleSelector = '[data-thread-title-trigger]';
  const sidebarThreads = {
    selector: `[${threadIDAttribute}]`,
    observedAttributes: [threadIDAttribute, 'data-thread-title-trigger'],
    localID(row) {
      const value = row?.getAttribute(threadIDAttribute) || '';
      return value.startsWith('local:') ? value.slice('local:'.length) || null : null;
    },
    titleElement(row) {
      return row?.querySelector(threadTitleSelector) || null;
    },
    title(row) {
      return String(row.querySelector(`${threadTitleSelector}, [data-marquee-text]`)?.textContent
        || [...row.childNodes].filter(node => !(node instanceof Element)
          || !node.matches('button, svg'))
          .map(node => node.textContent).join('')).trim();
    },
    changedIn(records) {
      const containsRow = node => node instanceof Element
        && (node.matches(sidebarThreads.selector) || Boolean(node.querySelector(sidebarThreads.selector)));
      return records.some(record => {
        if (record.type === 'attributes') return sidebarThreads.observedAttributes.includes(record.attributeName);
        const target = record.target instanceof Element ? record.target : record.target?.parentElement;
        return Boolean(target?.closest(sidebarThreads.selector))
          || [...record.addedNodes, ...record.removedNodes].some(containsRow);
      });
    },
  };

  function threadRows() {
    return [...document.querySelectorAll(sidebarThreads.selector)];
  }

  const projectAttributes = {
    row: 'data-app-action-sidebar-project-row',
    id: 'data-app-action-sidebar-project-id',
    name: 'data-app-action-sidebar-project-label',
  };
  const sidebarProjects = {
    selector: `[${projectAttributes.row}][${projectAttributes.id}]`,
    observedAttributes: Object.values(projectAttributes),
    metadata(row) {
      return {
        id: String(row?.getAttribute(projectAttributes.id) || '').trim(),
        name: String(row?.getAttribute(projectAttributes.name) || '').trim(),
      };
    },
    localPath(row) {
      const { id } = sidebarProjects.metadata(row);
      if (!id) return null;
      for (const fiber of parentFibers(row)) {
        const group = (fiber.memoizedProps || fiber.pendingProps)?.group;
        if (group?.projectId !== id || group.projectKind !== 'local') continue;
        const path = String(group.path || '');
        if (path.trim()) return path;
      }
      return null;
    },
    containingRow(element) {
      return element.closest(`[${projectAttributes.id}]`);
    },
    findRow(projectID) {
      return document.querySelector(`[${projectAttributes.id}="${CSS.escape(projectID)}"]`);
    },
    changedIn(records) {
      const selector = `[${projectAttributes.row}]`;
      const containsProject = node => node instanceof Element
        && (node.matches(selector) || Boolean(node.querySelector(selector)));
      return records.some(record => record.type === 'attributes'
        ? record.attributeName === projectAttributes.row || record.target.matches(selector)
        : [...record.addedNodes, ...record.removedNodes].some(containsProject));
    },
  };

  function projects() {
    const seen = new Set();
    return [...document.querySelectorAll(sidebarProjects.selector)].reduce((result, row) => {
      const { id, name } = sidebarProjects.metadata(row);
      if (!id || !name || seen.has(id)) return result;
      const path = sidebarProjects.localPath(row)?.trim() || '';
      seen.add(id);
      result.push({ id, name, path });
      return result;
    }, []);
  }

  function selectProject(projectID) {
    const row = sidebarProjects.findRow(projectID);
    if (!row) return false;
    for (const fiber of parentFibers(row)) {
      const props = fiber.memoizedProps || fiber.pendingProps;
      const select = props?.projectId === projectID ? props.selectAction?.onSelect : null;
      if (typeof select === 'function') {
        select();
        return true;
      }
    }
    row.click();
    return true;
  }

  function threadRow(threadID) {
    // Codex retains hidden workspace/sidebar copies. Clicking those rows can
    // select a stale chat surface instead of navigating the visible workspace.
    return [...document.querySelectorAll(
      `[${threadIDAttribute}="${CSS.escape(`local:${threadID}`)}"]`,
    )].find(isVisible) || null;
  }

  function isThreadSelected(threadID) {
    return threadRow(threadID)?.getAttribute('aria-current') === 'page'
      || activeComposerThreadID() === threadID;
  }

  function* activeComposerAncestorProps() {
    for (let host = composer()?.parentElement; host && host !== document.body; host = host.parentElement) {
      for (const fiber of parentFibers(host)) {
        yield fiber.memoizedProps || fiber.pendingProps;
      }
    }
  }

  function activeComposerThreadID() {
    for (const props of activeComposerAncestorProps()) {
      if (typeof props?.conversationId === 'string') return props.conversationId;
    }
    return null;
  }

  function selectedThreadID() {
    const composerID = activeComposerThreadID();
    if (composerID) return composerID;
    const row = threadRows().find((row) => isVisible(row) && row.getAttribute('aria-current') === 'page');
    return sidebarThreads.localID(row);
  }

  function activeComposerExplicitlyHasNoProject() {
    for (const props of activeComposerAncestorProps()) {
      if (props && Object.hasOwn(props, 'selectedProject')) return props.selectedProject === null;
    }
    return false;
  }

  function activeComposerProjectID() {
    for (const props of activeComposerAncestorProps()) {
      const project = props?.selectedProject;
      if (project?.type === 'local' && typeof project.projectId === 'string' && project.projectId.trim()) {
        return project.projectId.trim();
      }
    }
    return null;
  }

  function activeComposerProject() {
    const projectID = activeComposerProjectID();
    if (!projectID) return null;

    const projectRow = sidebarProjects.findRow(projectID);
    for (const fiber of parentFibers(projectRow)) {
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

  function threadUnreadStates() {
    const unreadStates = new Map();
    const fiberCache = new Map();
    threadRows().forEach((row) => {
      const threadID = sidebarThreads.localID(row);
      if (!threadID) return;
      let fiber = committedFiber(reactFiber(row), fiberCache);
      while (fiber) {
        const props = fiber.memoizedProps;
        if (props?.conversationId === threadID && typeof props?.isUnread === 'boolean') {
          unreadStates.set(props.conversationId, props.isUnread);
          break;
        }
        fiber = committedFiber(fiber.return, fiberCache);
      }
    });
    return unreadStates;
  }

  function cachedReadAction(value, visited) {
    if (!value || typeof value !== 'object' || visited.has(value)) return null;
    visited.add(value);
    if (typeof value.markThreadAsRead === 'function'
        && typeof value.markThreadAsUnread === 'function') return value.markThreadAsRead;
    const entries = Array.isArray(value) ? value : value.data;
    if (!Array.isArray(entries)) return null;
    for (const entry of entries) {
      const action = cachedReadAction(entry, visited);
      if (action) return action;
    }
    return null;
  }

  function markThreadsRead(threadIDs) {
    // Codex caches its sidebar action callbacks on the committed row fiber.
    // The read callback accepts any local task ID, including one outside the sidebar.
    const fiberCache = new Map();
    let markRead = null;
    for (const row of threadRows()) {
      if (!sidebarThreads.localID(row)) continue;
      let fiber = committedFiber(reactFiber(row), fiberCache);
      while (fiber && !markRead) {
        const visited = new Set();
        markRead = cachedReadAction(fiber.updateQueue?.memoCache?.data, visited);
        let hook = fiber.memoizedState;
        for (let count = 0; hook && !markRead && count < 100; count += 1) {
          markRead = cachedReadAction(hook.memoizedState, visited);
          hook = hook.next;
        }
        fiber = committedFiber(fiber.return, fiberCache);
      }
      if (markRead) break;
    }
    if (!markRead) return { available: false, failedIDs: threadIDs };
    const failedIDs = [];
    threadIDs.forEach((threadID) => {
      try { markRead({ conversationId: threadID, hostId: 'local' }); }
      catch { failedIDs.push(threadID); }
    });
    return { available: true, failedIDs };
  }

  function composer(promptDialogID = 'codex-dashboard-prompt-library-dialog') {
    return composerSelectors.flatMap((selector) => [...document.querySelectorAll(selector)])
      .find((element) => (
        !element.closest(`#${promptDialogID}, #${dashboardElements.elementIDs.todoPage}, #${dashboardElements.elementIDs.reviewPage}`)
          && element.getClientRects().length > 0
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
    for (const fiber of parentFibers(host)) {
      const props = fiber.pendingProps || fiber.memoizedProps;
      const view = props?.composerController?.view;
      if (
        view?.dom === composerElement
          && typeof view.focus === 'function'
          && typeof view.dispatch === 'function'
          && typeof view.state?.tr?.replaceSelection === 'function'
          && typeof view.state?.schema?.nodes?.paragraph?.create === 'function'
      ) return view;
    }
    return null;
  }

  function modelPickerTrigger(promptDialogID = 'codex-dashboard-prompt-library-dialog') {
    const activeComposer = composer(promptDialogID);
    let container = activeComposer?.parentElement;
    while (container && container !== document.body) {
      const trigger = [...container.querySelectorAll('[data-composer-navigation-target="reasoning"]')]
        .find(isVisible);
      if (trigger) return trigger;
      container = container.parentElement;
    }
    return [...document.querySelectorAll('[data-composer-navigation-target="reasoning"]')].find(isVisible) || null;
  }

  function modelPicker() {
    return [...document.querySelectorAll('[data-model-picker-view]')].find(isVisible) || null;
  }

  async function probeModelPickerControls(timeout = 1200) {
    const trigger = modelPickerTrigger();
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
      const hasSupportedEffort = COMPOSER_PRESET_SCHEMA.reasoningEfforts.includes(effort);
      return hasSupportedEffort
        && Boolean(picker.querySelector('[data-model-picker-view-toggle]'))
        && Boolean(picker.querySelector('[data-reasoning-slider]'));
    } finally {
      if (!wasExpanded && trigger.getAttribute('aria-expanded') === 'true') {
        modelPicker()?.dispatchEvent(new KeyboardEvent('keydown', {
          key: 'Escape', code: 'Escape', bubbles: true,
        }));
        await waitFor(() => trigger.getAttribute('aria-expanded') !== 'true');
      }
    }
  }

  // The commit dialog exposes stable command values, independent of UI language.
  // Read its target rather than the chat checkout: the repository picker can
  // select another repository, and remote hosts must never use local Git state.
  function pushControls() {
    for (const dialog of document.querySelectorAll('[role="dialog"]')) {
      if (!isVisible(dialog)) continue;
      const props = [...parentFibers(dialog)].map(fiber => fiber.memoizedProps)
        .find(props => typeof props?.open === 'boolean'
          && typeof props.enablePushActions === 'boolean'
          && typeof props.onOpenChange === 'function'
          && props.target && typeof props.target.root === 'string');
      if (!props) {
        // Recognize the command group even if its React target contract changed.
        // This is a warning, never permission to alter an unidentified dialog.
        if (dialog.querySelector('[cmdk-item][data-value="commit-and-push"]')) {
          return { compatible: false, unsupported: true };
        }
        continue;
      }
      if (!props.open || !props.enablePushActions) continue;
      const roots = dialog.querySelectorAll('[cmdk-root]');
      const root = roots.length === 1 ? roots[0] : null;
      const items = root ? ['commit', 'commit-and-push', 'push'].map(value => {
        const matches = root.querySelectorAll(`[cmdk-item][role="option"][data-value="${value}"]`);
        return matches.length === 1 ? matches[0] : null;
      }) : [];
      return {
        dialog, root, items,
        compatible: Boolean(root && root.hasAttribute('data-codex-shortcut-capture')
          && items.length === 3 && items.every(Boolean)
          && props.target.root.startsWith('/') && typeof props.conversationId === 'string'),
        threadID: props.conversationId,
        path: props.target.root,
        local: props.target.hostConfig?.id === 'local',
        hostConfig: props.target.hostConfig,
      };
    }
    return null;
  }

  function pushControlHostAttribute(item, name) {
    // React may change a disabled state to the same value we temporarily applied.
    // Prefer its current rendered props when restoring, including that case.
    const props = reactFiber(item)?.memoizedProps;
    if (!props || !Object.hasOwn(props, name)) return undefined;
    return props[name] == null ? null : String(props[name]);
  }

  const chatHeaderSelector = '[data-app-shell-header-toolbar], [data-app-shell-header-slot="end"]';

  function chatHeaderActionsHost() {
    const composerID = activeComposerThreadID();
    if ((!composerID || composerID.startsWith('client-new-thread:')) && activeComposerProjectID()) {
      // Blank project chats have an end slot but no Share or Summary buttons.
      return [...document.querySelectorAll('[data-app-shell-header-slot="end"] [data-app-shell-header-slot-content]')]
        .find(element => isVisible(element) && !element.closest('[aria-hidden="true"], [inert]')) || null;
    }
    const buttons = document.querySelectorAll(
      'button[aria-label="Toggle summary"], button[aria-label="Toggle pinned summary"]',
    );
    for (const button of buttons) {
      const header = button.closest(chatHeaderSelector);
      if (!header || !isVisible(button) || button.closest('[aria-hidden="true"], [inert]')) continue;
      const slot = button.closest('[data-app-shell-header-slot-content]');
      if (slot && header.contains(slot)) return slot;
      const focusArea = button.closest('[data-app-shell-focus-area]');
      return focusArea && header.contains(focusArea) ? focusArea.parentElement : button.parentElement;
    }
    return null;
  }

  // Summary panels for other chats remain mounted, including while hidden.
  // Match the native Git scope to the selected chat before reading callbacks.
  function headerGitContext() {
    const containsMessage = (element, ids, depth = 0) => {
      if (!element || depth > 8) return false;
      if (Array.isArray(element)) return element.some(child => containsMessage(child, ids, depth + 1));
      return ids.includes(element.props?.id) || containsMessage(element.props?.children, ids, depth + 1);
    };
    const threadID = selectedThreadID();
    if (!threadID) return null;
    const isSelectedScope = props => props?.surface === 'summary-panel'
      && props.conversationId === threadID
      && typeof props.target?.root === 'string'
      && props.target.root.startsWith('/')
      && props.target.hostId === 'local' && props.registerCommands === true;
    for (const trigger of document.querySelectorAll('button[aria-label="Git actions"]')) {
      const ancestors = [...parentFibers(trigger)].map(fiber => fiber.memoizedProps);
      const scope = ancestors.find(isSelectedScope);
      const menu = ancestors.find(props => props?.triggerButton?.props?.label === 'Git actions'
        && typeof props.open === 'boolean' && typeof props.onOpenChange === 'function'
        && containsMessage(props.children, ['localConversation.gitActions.commit', 'localConversation.gitActions.cancelWorkflow']));
      if (!scope || !menu) continue;
      const workflowRunning = containsMessage(menu.children, ['localConversation.gitActions.cancelWorkflow']);
      return { threadID: scope.conversationId, path: scope.target.root, hostID: scope.target.hostId, trigger, menu, workflowRunning };
    }
    // The summary still registers the native Git command when Git-based diffs
    // are disabled, but omits the Git menu from the checkout section.
    for (const button of document.querySelectorAll('[data-summary-panel-variant] button[aria-label="Actions"]')) {
      const ancestors = [...parentFibers(button)];
      const scope = ancestors.map(fiber => fiber.memoizedProps)
        .find(props => isSelectedScope(props) && props.deferQueries === true);
      if (!scope) continue;
      const summary = ancestors.find(fiber => fiber.memoizedProps?.surface === 'summary-panel'
        && fiber.memoizedProps.deferGitQueries === true && fiber.memoizedProps.registerCommands === true);
      const registrar = summary?.child;
      if (registrar?.memoizedProps?.deferQueries !== true) continue;
      // Read this checkout's registration. A window-wide command could route to
      // another mounted chat, and the full Git command can push without a dialog.
      const lastEffect = registrar.child?.updateQueue?.lastEffect;
      if (!lastEffect) continue;
      for (let effect = lastEffect.next; effect; effect = effect.next) {
        const deps = effect.deps;
        if (deps?.[3] === 'git.commit' && typeof deps[2] === 'function') {
          return {
            threadID: scope.conversationId, path: scope.target.root, hostID: scope.target.hostId,
            workflowRunning: deps[1] === false,
            openCommitDialog: deps[1] === true && typeof effect.inst?.destroy === 'function'
              ? () => deps[2](undefined, 'toolbar') : null,
          };
        }
        if (effect === lastEffect) break;
      }
    }
    return null;
  }

  function gitActionsMenu(trigger) {
    const menuID = trigger.getAttribute('aria-controls');
    const menu = menuID ? document.getElementById(menuID) : null;
    return menu?.getAttribute('role') === 'menu' && isVisible(menu) ? menu : null;
  }

  function gitActionMenuItem(menu, action) {
    return [...menu.querySelectorAll('[role="menuitem"]')].find((item) => (
      isVisible(item)
        && !item.disabled
        && item.getAttribute('aria-disabled') !== 'true'
        && item.textContent.trim() === action
    )) || null;
  }

  return {
    hasHostSpeechInput,
    hasActiveSpeechInput,
    sidebar,
    navigation,
    profileMenu,
    profileMenuTrigger,
    profileMenuAccountAnchor,
    threadRows,
    sidebarThreads,
    projects,
    sidebarProjects,
    selectProject,
    threadRow,
    isThreadSelected,
    activeComposerThreadID,
    selectedThreadID,
    activeComposerExplicitlyHasNoProject,
    activeComposerProjectID,
    activeComposerProject,
    threadUnreadStates,
    markThreadsRead,
    composer,
    composerAddButton,
    composerEditorView,
    modelPickerTrigger,
    modelPicker,
    probeModelPickerControls,
    pushControls,
    pushControlHostAttribute,
    chatHeaderSelector,
    chatHeaderActionsHost,
    headerGitContext,
    gitActionsMenu,
    gitActionMenuItem,
  };
})();
