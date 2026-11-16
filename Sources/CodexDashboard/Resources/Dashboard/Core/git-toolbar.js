function createGitToolbar({ findThread, prefetchRemote, remoteState, subscribeRemote, checkBranchAhead, checkWorkingTree, repositoryState, projectGitActions }) {
  let toolbar;
  let observer;
  let frame;
  let syncTimer;
  let pending;
  let positionedMenu;
  let menuContext;
  let menuAnchor;
  let destroyed = false;
  let unsubscribeRemote;
  let missingSince;
  let inspectedThreadID;
  let projectRefreshTimer;
  let feedback;
  let feedbackContext;
  let feedbackMessage;
  let feedbackTimer;
  const projectStatuses = new Map();
  const menuChanges = new Map();
  const combinedPushChecks = new Map();
  const commitChecks = new Map();
  const actions = ['Commit', 'Commit & push', 'Push'];

  const sameContext = (a, b) => Boolean(a && b && a.threadID === b.threadID
    && a.path === b.path && a.hostID === b.hostID && a.projectID === b.projectID);

  function isProjectChat(threadID) {
    if (threadID !== codexUIContracts.selectedThreadID()) return false;
    // Older chats can belong to a project through folder grouping without an
    // explicit project ID on either the server thread or its composer.
    const thread = findThread(threadID);
    if (thread?.projectID || (thread?.projectGroupPath && thread.sharesGroupRepository)) return true;
    if (codexUIContracts.activeComposerExplicitlyHasNoProject()) return false;
    return Boolean(codexUIContracts.activeComposerProjectID());
  }

  function selectedProjectContext() {
    const composerID = codexUIContracts.activeComposerThreadID();
    if (composerID && !composerID.startsWith('client-new-thread:')) return null;
    const project = codexUIContracts.activeComposerProject();
    const projectID = codexUIContracts.activeComposerProjectID();
    if (!project?.path || !projectID) return null;
    prefetchRemote(project.path);
    if (repositoryState(project.path) !== true) return null;
    return {
      threadID: null, projectID,
      path: project.path, hostID: 'local', newChat: true,
    };
  }

  function gitContext() {
    const project = selectedProjectContext();
    if (project) return project;
    const threadID = codexUIContracts.selectedThreadID();
    return isProjectChat(threadID) ? codexUIContracts.headerGitContext() : null;
  }

  function refreshProjectStatus(context) {
    const previous = projectStatuses.get(context.path);
    if (previous?.loading || (previous && Date.now() - previous.checkedAt < 2000)) return;
    const request = { ...previous, loading: true };
    projectStatuses.set(context.path, request);
    Promise.all([checkWorkingTree(context.path), checkBranchAhead(context.path)]).then(([changes, ahead]) => {
      if (destroyed || projectStatuses.get(context.path) !== request) return;
      const status = changes === null || ahead === null ? null
        : changes > 0 ? (ahead > 0 ? 'uncommittedChangesAndUnpushedCommits' : 'uncommittedChanges')
          : (ahead > 0 ? 'unpushedCommits' : 'clean');
      projectStatuses.set(context.path, { status, checkedAt: Date.now(), loading: false });
      sync();
    });
  }

  function repositoryStatus(context) {
    if (context.newChat) return projectStatuses.get(context.path)?.status ?? null;
    const thread = findThread(context.threadID);
    return thread?.sharesGroupRepository ? thread.projectGitStatus : null;
  }

  function hasUnpushedCommits(status) {
    return status === 'unpushedCommits' || status === 'uncommittedChangesAndUnpushedCommits';
  }

  function hasUncommittedChanges(status) {
    return status === 'uncommittedChanges' || status === 'uncommittedChangesAndUnpushedCommits';
  }

  function reconcileOperation(context, checks, hasChanges, readCount, { clearOnSnapshot = true } = {}) {
    const check = checks.get(context.path);
    if (!check) return;
    const status = repositoryStatus(context);
    if (pending || context.workflowRunning) return;
    if (['clean', 'uncommittedChanges', 'unpushedCommits', 'uncommittedChangesAndUnpushedCommits'].includes(status)
      && !hasChanges(status)) {
      clearTimeout(check.timer);
      check.timer = undefined;
      if (clearOnSnapshot) checks.delete(context.path);
      return;
    }
    if (!hasChanges(status) || check.running || check.timer !== undefined) return;
    check.running = true;
    readCount(context.path).then(count => {
      if (checks.get(context.path) !== check) return;
      check.running = false;
      const current = gitContext();
      if (current?.path === context.path && !pending && !current.workflowRunning && count > 0) {
        checks.delete(context.path);
        sync();
        return;
      }
      // The catalog can still contain a snapshot from before the operation finished.
      // Recheck while it disagrees, or if Git temporarily could not report its count.
      check.timer = setTimeout(() => {
        check.timer = undefined;
        sync();
      }, 1000);
    });
  }

  function disabledReason(context, action) {
    if (context.workflowRunning || projectGitActions.isRunning(context.path)) return 'Wait for the current Git operation to finish.';
    if (!context.newChat && !context.menu && !context.openCommitDialog) return 'Codex is preparing Git actions for this chat.';
    const thread = findThread(context.threadID);
    if (thread?.gitActionsBlockedUntilCompletion) return 'Wait for a response to finish without interruption before committing or pushing these files.';
    if (['Push', 'Commit & push'].includes(action)) {
      const remote = remoteState(context.path);
      if (remote !== true) return remote === false
        ? 'No Git remote is configured for this repository.' : 'Checking Git remotes…';
    }
    // Use the repository snapshot for availability; hidden native menus can retain
    // a pre-commit nothing-to-push hint. Native selection still checks enabled items.
    // Group status is valid only when this chat uses that same repository.
    const status = repositoryStatus(context);
    if (!['clean', 'uncommittedChanges', 'unpushedCommits', 'uncommittedChangesAndUnpushedCommits'].includes(status)) {
      return 'Repository status is not available yet.';
    }
    const hasChanges = hasUncommittedChanges(status);
    if (action === 'Push' && !hasUnpushedCommits(status)) return 'No unpushed commits.';
    if (action === 'Push' && combinedPushChecks.has(context.path)) return 'Checking for unpushed commits…';
    if (action !== 'Push' && !hasChanges) return 'No changes to commit.';
    if (action !== 'Push' && commitChecks.has(context.path)) return 'Checking for uncommitted changes…';
    return '';
  }

  function restoreMenuItems() {
    for (const [item, attributes] of menuChanges) {
      for (const [name, previous] of attributes) {
        const hostValue = codexUIContracts.pushControlHostAttribute(item, name);
        const value = hostValue === undefined ? previous : hostValue;
        if (value === null) item.removeAttribute(name);
        else item.setAttribute(name, value);
      }
    }
    menuChanges.clear();
  }

  function restoreMenu() {
    restoreMenuItems();
    positionedMenu?.removeAttribute('data-dashboard-git-menu');
    positionedMenu?.style.removeProperty('--dashboard-git-menu-x');
    positionedMenu?.style.removeProperty('--dashboard-git-menu-y');
    positionedMenu = undefined;
  }

  function closeMenu() {
    if (menuContext?.trigger.isConnected) menuContext.menu.onOpenChange(false);
    restoreMenu();
    menuContext = undefined;
    menuAnchor = undefined;
  }

  function positionMenu() {
    const menu = menuContext && codexUIContracts.gitActionsMenu(menuContext.trigger);
    const wrapper = menu?.closest('[data-radix-popper-content-wrapper]');
    if (!wrapper || !menuAnchor?.isConnected) return;
    if (positionedMenu !== wrapper) {
      restoreMenu();
      positionedMenu = wrapper;
    }
    const anchor = menuAnchor.getBoundingClientRect();
    const width = wrapper.getBoundingClientRect().width;
    // Popper wrappers use CSS pixels even when the app content is zoomed.
    const scale = wrapper.offsetWidth ? width / wrapper.offsetWidth : 1;
    const x = Math.max(8, Math.min(anchor.right - width, window.innerWidth - width - 8));
    const y = anchor.bottom + 6;
    wrapper.setAttribute('data-dashboard-git-menu', '');
    const set = (name, value) => {
      if (wrapper.style.getPropertyValue(name) !== value) wrapper.style.setProperty(name, value);
    };
    set('--dashboard-git-menu-x', `${x / scale}px`);
    set('--dashboard-git-menu-y', `${y / scale}px`);
    if (remoteState(menuContext.path) !== true) {
      const push = [...menu.querySelectorAll('[role="menuitem"]')].find(item => item.textContent.trim() === 'Push');
      if (push) {
        if (!menuChanges.has(push)) menuChanges.set(push, new Map());
        for (const [name, value] of [['aria-disabled', 'true'], ['data-disabled', ''],
          ['title', remoteState(menuContext.path) === false
            ? 'No Git remote is configured for this repository.' : 'Checking Git remotes…']]) {
          if (push.getAttribute(name) === value) continue;
          const attributes = menuChanges.get(push);
          if (!attributes.has(name)) attributes.set(name, push.getAttribute(name));
          push.setAttribute(name, value);
        }
      }
    } else if (menuChanges.size) restoreMenuItems();
  }

  async function selectDialogAction(context, operation, action) {
    const command = { Commit: 'commit', 'Commit & push': 'commit-and-push', Push: 'push' }[action];
    const handoff = await domUtils.waitFor(() => {
      if (destroyed || pending !== operation
        || (!context.newChat && !isProjectChat(context.threadID))
        || !sameContext(context, gitContext())) return true;
      const dialog = codexUIContracts.pushControls();
      if (!dialog?.compatible || !dialog.local || dialog.threadID !== context.threadID
        || dialog.path !== context.path) return null;
      if (disabledReason(context, action)) return null;
      const option = dialog.items.find(item => item.getAttribute('data-value') === command);
      if (!option || option.getAttribute('aria-disabled') === 'true'
        || option.getAttribute('data-disabled') === 'true' || option.disabled) return null;
      if (action !== 'Push') {
        clearTimeout(commitChecks.get(context.path)?.timer);
        commitChecks.set(context.path, { running: false });
      }
      if (action === 'Commit & push') {
        clearTimeout(combinedPushChecks.get(context.path)?.timer);
        combinedPushChecks.set(context.path, { running: false });
      }
      option.click();
      return { selected: dialog.dialog };
    }, { timeout: 5000, interval: 50 });
    if (handoff?.selected) {
      await domUtils.waitFor(() => destroyed || !handoff.selected.isConnected
        || !handoff.selected.querySelector(`[cmdk-item][data-value="${command}"]`),
      { timeout: 1000, interval: 16 });
    }
  }

  function showFeedback(context, message, completed = false) {
    clearTimeout(feedbackTimer);
    feedbackContext = context;
    feedbackMessage = message;
    if (feedback) {
      feedback.textContent = message;
      feedback.hidden = !sameContext(context, gitContext());
    }
    if (completed) {
      feedbackTimer = setTimeout(() => {
        feedbackMessage = undefined;
        feedbackContext = undefined;
        if (feedback) feedback.hidden = true;
      }, 3000);
    }
  }

  async function activate(action, anchor) {
    if (pending) return;
    const context = gitContext();
    if (!context || (!context.newChat && !isProjectChat(context.threadID))) return;
    if (disabledReason(context, action)) { sync(); return; }
    closeMenu();
    const operation = { context };
    pending = operation;
    const nativeAction = action === 'Commit & push' ? 'Commit' : action;
    document.body.setAttribute('data-dashboard-git-handoff', '');
    sync();
    try {
      if (context.newChat) {
        await projectGitActions.run(context.path, action, {
          isCurrent: () => !destroyed && sameContext(context, selectedProjectContext()),
          report: (message, completed) => showFeedback(context, message, completed),
        });
        return;
      }
      if (context.openCommitDialog) {
        context.openCommitDialog();
        await selectDialogAction(context, operation, action);
        return;
      }
      menuContext = context;
      menuAnchor = anchor;
      context.menu.onOpenChange(true);
      const item = await domUtils.waitFor(() => {
        if (destroyed || pending !== operation
          || (!context.newChat && !isProjectChat(context.threadID))
          || !sameContext(context, gitContext())) return { cancelled: true };
        const menu = codexUIContracts.gitActionsMenu(context.trigger);
        positionMenu();
        return menu && codexUIContracts.gitActionMenuItem(menu, nativeAction);
      }, { timeout: 3000, interval: 50 });
      if (item?.cancelled) {
        closeMenu();
        return;
      }
      if (item) {
        if (disabledReason(context, action)) { closeMenu(); return; }
        // Native menu selection retains Codex's disabled states and Git workflow.
        item.click();
        closeMenu();
        await selectDialogAction(context, operation, action);
      }
      // Unavailable actions leave the native menu visible with its explanation.
      if (!item) {
        toolbar.title = `${action} is unavailable. Check the Git menu.`;
      }
    } catch (error) {
      closeMenu();
      if (context.newChat) showFeedback(context, String(error.message).slice(0, 600));
      else if (toolbar) toolbar.title = 'Codex could not open Git actions. Try again.';
    } finally {
      if (context.newChat) projectStatuses.delete(context.path);
      document.body.removeAttribute('data-dashboard-git-handoff');
      if (pending === operation) pending = undefined;
      if (!destroyed) sync();
    }
  }

  function sync() {
    const host = codexUIContracts.chatHeaderActionsHost();
    const context = host ? gitContext() : null;
    clearTimeout(projectRefreshTimer);
    projectRefreshTimer = undefined;
    if (menuContext && !sameContext(context, menuContext)) closeMenu();
    if (!host || !context) {
      toolbar?.remove();
      return;
    }
    prefetchRemote(context.path);
    if (context.newChat) {
      refreshProjectStatus(context);
      projectRefreshTimer = setTimeout(sync, 2000);
    }
    // A snapshot can miss the commit and then catch it before the push. Keep
    // requiring a fresh ahead count whenever a snapshot claims commits remain.
    reconcileOperation(context, combinedPushChecks, hasUnpushedCommits, checkBranchAhead, { clearOnSnapshot: false });
    reconcileOperation(context, commitChecks, hasUncommittedChanges, checkWorkingTree);
    if (!toolbar) {
      toolbar = document.createElement('div');
      toolbar.id = dashboardElements.elementIDs.gitToolbar;
      toolbar.className = 'dashboard-git-toolbar';
      toolbar.setAttribute('role', 'group');
      toolbar.setAttribute('aria-label', 'Repository actions');
      for (const action of actions) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = action;
        button.dataset.gitAction = action;
        button.title = action;
        button.addEventListener('click', () => activate(action, button));
        toolbar.append(button);
      }
    }
    if (!feedback) {
      feedback = document.createElement('div');
      feedback.className = 'dashboard-git-feedback';
      feedback.setAttribute('role', 'status');
      toolbar.append(feedback);
    }
    feedback.hidden = !feedbackMessage || !sameContext(context, feedbackContext);
    if (!feedback.hidden) feedback.textContent = feedbackMessage;
    if (toolbar.parentElement !== host) host.prepend(toolbar);
    for (const button of toolbar.querySelectorAll('button')) {
      const reason = disabledReason(context, button.dataset.gitAction);
      const disabled = Boolean(pending) || Boolean(reason);
      if (button.disabled !== disabled) button.disabled = disabled;
      const title = reason || button.dataset.gitAction;
      if (button.title !== title) button.title = title;
    }
    positionMenu();
    if (positionedMenu && !positionedMenu.isConnected) restoreMenu();
  }

  function readCompatibility() {
    const composer = codexUIContracts.composer();
    const threadID = codexUIContracts.selectedThreadID();
    // Confirm eligibility independently of the toolbar anchor and native Git
    // menu, since a Codex update can remove either of them.
    const selectedProject = selectedProjectContext();
    const contextID = selectedProject?.projectID ?? threadID;
    const eligible = (selectedProject || isProjectChat(threadID)) && domUtils.isVisible(composer)
      && !composer.closest('[aria-hidden="true"], [inert]')
      && (selectedProject || findThread(threadID)?.sharesGroupRepository || gitContext());
    if (!eligible || inspectedThreadID !== contextID) {
      missingSince = undefined;
      inspectedThreadID = eligible ? contextID : undefined;
    }
    if (!eligible) return 'pending';
    if (domUtils.isVisible(toolbar) && actions.every(action => {
      const button = toolbar.querySelector(`button[data-git-action="${action}"]`);
      return domUtils.isVisible(button);
    })) {
      missingSince = undefined;
      return 'compatible';
    }
    // Let the toolbar's normal mount and repair finish after navigation.
    missingSince ??= performance.now();
    return performance.now() - missingSince >= 750 ? 'missing' : 'pending';
  }

  function scheduleSync() {
    if (frame !== undefined || destroyed) return;
    const run = () => {
      cancelAnimationFrame(frame);
      clearTimeout(syncTimer);
      frame = undefined;
      syncTimer = undefined;
      if (!destroyed) sync();
    };
    frame = requestAnimationFrame(run);
    // Hidden host windows can suspend animation frames during navigation.
    syncTimer = setTimeout(run, 80);
  }

  function handleMutations(records) {
    const hostSelector = `${codexUIContracts.chatHeaderSelector}, button[aria-label="Git actions"], [data-summary-panel-variant], [data-radix-popper-content-wrapper], [role="dialog"]`;
    const containsHost = node => node instanceof Element && (node.matches(hostSelector)
      || (node.firstElementChild && node.querySelector(`${hostSelector}, button[aria-label="Git actions"]`)));
    if (records.some(record => {
      if (record.target.closest?.('.dashboard-git-toolbar')) return false;
      if (record.target.closest?.(hostSelector)) return true;
      if (record.type === 'attributes') return record.attributeName === 'aria-current'
        || (['aria-hidden', 'inert'].includes(record.attributeName) && containsHost(record.target));
      return [...record.addedNodes, ...record.removedNodes].some(containsHost);
    })) scheduleSync();
  }

  function blockRemoteAction(event) {
    if (!menuContext || remoteState(menuContext.path) === true) return;
    const item = event.target instanceof Element ? event.target.closest('[role="menuitem"]') : null;
    if (!item || !positionedMenu?.contains(item) || item.textContent.trim() !== 'Push') return;
    if (event.type === 'keydown' && !['Enter', ' '].includes(event.key)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  function mount() {
    destroyed = false;
    if (!observer) {
      unsubscribeRemote = subscribeRemote(scheduleSync);
      observer = new MutationObserver(handleMutations);
      observer.observe(document.body, { childList: true, subtree: true, attributes: true,
      attributeFilter: ['aria-hidden', 'aria-expanded', 'aria-current', 'aria-disabled', 'data-disabled', 'disabled', 'inert', 'style'] });
      window.addEventListener('resize', scheduleSync);
      document.addEventListener('click', blockRemoteAction, true);
      document.addEventListener('keydown', blockRemoteAction, true);
    }
    sync();
  }

  function destroy() {
    destroyed = true;
    document.body.removeAttribute('data-dashboard-git-handoff');
    pending = undefined;
    for (const check of combinedPushChecks.values()) clearTimeout(check.timer);
    combinedPushChecks.clear();
    for (const check of commitChecks.values()) clearTimeout(check.timer);
    commitChecks.clear();
    missingSince = undefined;
    inspectedThreadID = undefined;
    clearTimeout(projectRefreshTimer);
    projectStatuses.clear();
    observer?.disconnect();
    unsubscribeRemote?.();
    unsubscribeRemote = undefined;
    observer = undefined;
    if (frame !== undefined) cancelAnimationFrame(frame);
    if (syncTimer !== undefined) clearTimeout(syncTimer);
    frame = undefined;
    syncTimer = undefined;
    window.removeEventListener('resize', scheduleSync);
    document.removeEventListener('click', blockRemoteAction, true);
    document.removeEventListener('keydown', blockRemoteAction, true);
    closeMenu();
    toolbar?.remove();
    toolbar = undefined;
    clearTimeout(feedbackTimer);
    feedback = undefined;
    feedbackContext = undefined;
    feedbackMessage = undefined;
  }

  return { mount, sync, destroy, readCompatibility };
}
