function createGitToolbar({ findThread, prefetchRemote, remoteState, subscribeRemote }) {
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
  const menuChanges = new Map();

  const sameContext = (a, b) => Boolean(a && b && a.threadID === b.threadID
    && a.path === b.path && a.hostID === b.hostID);

  function disabledReason(context, action) {
    if (!action || action === 'Git') return '';
    const thread = findThread(context.threadID);
    if (thread?.runState === 'running') return 'Wait for this chat to finish running.';
    if (['Push', 'Commit & push'].includes(action)) {
      const remote = remoteState(context.path);
      if (remote !== true) return remote === false
        ? 'No Git remote is configured for this repository.' : 'Checking Git remotes…';
    }
    // Group status is valid only when this chat uses that same repository.
    const status = thread?.sharesGroupRepository ? thread.projectGitStatus : null;
    if (!['clean', 'uncommittedChanges', 'unpushedCommits', 'uncommittedChangesAndUnpushedCommits'].includes(status)) {
      return 'Repository status is not available yet.';
    }
    const hasChanges = ['uncommittedChanges', 'uncommittedChangesAndUnpushedCommits'].includes(status);
    const hasUnpushed = ['unpushedCommits', 'uncommittedChangesAndUnpushedCommits'].includes(status);
    if (action === 'Push' && !hasUnpushed) return 'No unpushed commits.';
    if (action !== 'Push' && !hasChanges) return 'No changes to commit.';
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

  async function activate(action, anchor) {
    if (pending) return;
    const context = codexUIContracts.headerGitContext();
    if (!context) return;
    if (disabledReason(context, action)) { sync(); return; }
    if (!action && sameContext(context, menuContext) && context.menu.open) {
      closeMenu();
      return;
    }
    closeMenu();
    const operation = { context };
    pending = operation;
    menuContext = context;
    menuAnchor = anchor;
    const commitAndPush = action === 'Commit & push';
    const nativeAction = commitAndPush ? 'Commit' : action;
    if (nativeAction === 'Commit') prefetchRemote(context.path);
    context.menu.onOpenChange(true);
    sync();
    try {
      const item = await domUtils.waitFor(() => {
        if (destroyed || pending !== operation
          || !sameContext(context, codexUIContracts.headerGitContext())) return { cancelled: true };
        const menu = codexUIContracts.gitActionsMenu(context.trigger);
        positionMenu();
        if (!action) return menu;
        return menu && codexUIContracts.gitActionMenuItem(menu, nativeAction);
      }, { timeout: action ? 3000 : 1200, interval: 50 });
      if (item?.cancelled) {
        closeMenu();
        return;
      }
      if (action && item) {
        if (disabledReason(context, action)) { closeMenu(); return; }
        // Native menu selection retains Codex's disabled states and Git workflow.
        item.click();
        closeMenu();
        if (commitAndPush) {
          await domUtils.waitFor(() => {
            if (destroyed || pending !== operation
              || !sameContext(context, codexUIContracts.headerGitContext())) return true;
            const dialog = codexUIContracts.pushControls();
            if (!dialog?.compatible || dialog.threadID !== context.threadID
              || dialog.path !== context.path || dialog.hostConfig?.id !== context.hostID) return null;
            const combined = dialog.items[1];
            if (disabledReason(context, action)) return true;
            if (combined.getAttribute('aria-disabled') === 'true' || combined.getAttribute('data-disabled') === 'true') return null;
            combined.click();
            return true;
          }, { timeout: 3000, interval: 50 });
        }
      }
      // Unavailable actions leave the native menu visible with its explanation.
      if (!item) {
        toolbar.title = `${action || 'Git actions'} is unavailable. Check the Git menu.`;
      }
    } catch {
      closeMenu();
      if (toolbar) toolbar.title = 'Codex could not open Git actions. Try again.';
    } finally {
      if (pending === operation) pending = undefined;
      if (!destroyed) sync();
    }
  }

  function sync() {
    const host = codexUIContracts.gitToolbarHost();
    const context = host ? codexUIContracts.headerGitContext() : null;
    if (menuContext && !sameContext(context, menuContext)) closeMenu();
    if (!host || !context) {
      toolbar?.remove();
      return;
    }
    prefetchRemote(context.path);
    if (!toolbar) {
      toolbar = document.createElement('div');
      toolbar.id = dashboardElements.elementIDs.gitToolbar;
      toolbar.className = 'dashboard-git-toolbar';
      toolbar.setAttribute('role', 'group');
      toolbar.setAttribute('aria-label', 'Repository actions');
      for (const action of ['Commit', 'Commit & push', 'Push', 'Git']) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = action === 'Git' ? 'Git ▾' : action;
        button.dataset.gitAction = action;
        button.title = action === 'Git' ? 'Git actions' : action;
        if (action === 'Git') {
          button.setAttribute('aria-haspopup', 'menu');
          button.setAttribute('aria-label', 'Open Git actions');
        }
        button.addEventListener('click', () => activate(action === 'Git' ? null : action, button));
        toolbar.append(button);
      }
    }
    if (toolbar.parentElement !== host) host.prepend(toolbar);
    for (const button of toolbar.querySelectorAll('button')) {
      const reason = disabledReason(context, button.dataset.gitAction);
      const disabled = Boolean(pending) || Boolean(reason);
      if (button.disabled !== disabled) button.disabled = disabled;
      const title = reason || (button.dataset.gitAction === 'Git' ? 'Git actions' : button.dataset.gitAction);
      if (button.title !== title) button.title = title;
      if (button.dataset.gitAction === 'Git') {
        const expanded = String(Boolean(sameContext(context, menuContext) && context.menu.open));
        if (button.getAttribute('aria-expanded') !== expanded) button.setAttribute('aria-expanded', expanded);
      }
    }
    positionMenu();
    if (positionedMenu && !positionedMenu.isConnected) restoreMenu();
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
    const hostSelector = '[data-app-shell-header-toolbar], [data-summary-panel-variant], [data-radix-popper-content-wrapper], [role="dialog"]';
    const containsHost = node => node instanceof Element && (node.matches(hostSelector)
      || (node.firstElementChild && node.querySelector(`${hostSelector}, button[aria-label="Git actions"]`)));
    if (records.some(record => {
      if (record.target.closest?.('.dashboard-git-toolbar')) return false;
      if (record.target.closest?.(hostSelector)) return true;
      if (record.type === 'attributes') return record.attributeName === 'aria-current'
        || (record.attributeName === 'aria-hidden' && containsHost(record.target));
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
        attributeFilter: ['aria-hidden', 'aria-expanded', 'aria-current', 'aria-disabled', 'data-disabled', 'disabled', 'style'] });
      window.addEventListener('resize', scheduleSync);
      document.addEventListener('click', blockRemoteAction, true);
      document.addEventListener('keydown', blockRemoteAction, true);
    }
    sync();
  }

  function destroy() {
    destroyed = true;
    pending = undefined;
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
  }

  return { mount, sync, destroy };
}
