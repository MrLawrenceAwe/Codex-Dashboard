const accountPopover = (() => {
  const triggerAttribute = 'data-codex-accounts-trigger';
  const panelID = 'codex-accounts-panel';
  let snapshot = { accounts: [], activeAccountID: null, statusMessage: null, isBusy: false };
  let snapshotFingerprint = '';
  let observer;
  let outsidePointerHandler;
  let outsidePointerTimer;
  let escapeHandler;
  let retainPanelUntilActionCompletes = false;
  let actionProgress = null;
  const actions = [];

  function queue(kind, accountID = null) {
    if (snapshot.isBusy || actions.length) return;
    // Codex closes its profile menu for clicks inside our separate overlay,
    // removing the trigger along with it. Keep the account panel mounted until
    // native code publishes the action's resulting snapshot so failures (for
    // example, an account switch blocked by an active task) remain visible.
    retainPanelUntilActionCompletes = true;
    actions.push({ kind, accountID });
    actionProgress = kind === 'addAccount'
      ? 'Sign-in request queued…'
      : 'Account request queued…';
    renderPanel();
  }

  function takeNextAction() {
    const action = actions.shift() ?? null;
    if (action) {
      actionProgress = 'Request received. Checking Codex state…';
      renderPanel();
    }
    return JSON.stringify(action);
  }

  function accountMarkup(account) {
    const disabled = snapshot.isBusy || actions.length || account.isRefreshing ? ' disabled' : '';
    const initial = domUtils.escapeHTML(account.name.trim().slice(0, 1).toUpperCase() || '?');
    const usage = account.usageLines.map(usageMarkup).join('');
    return `<section class="codex-accounts-card" data-account-id="${account.id}">
      <div class="codex-accounts-heading">
        <span class="codex-accounts-avatar">${initial}</span>
        <strong>${domUtils.escapeHTML(account.name)}</strong>
        ${account.isActive ? '<span class="codex-accounts-active"><i></i>Active</span>' : ''}
      </div>
      <div class="codex-accounts-usage-list">${usage}</div>
      ${account.errorMessage ? `<div class="codex-accounts-error">${domUtils.escapeHTML(account.errorMessage)}</div>` : ''}
      <div class="codex-accounts-actions">
        ${account.isActive ? '' : `<button class="is-primary" data-account-action="${account.requiresSignIn ? 'sign-in' : 'switch'}"${disabled}>${account.requiresSignIn ? 'Sign in' : 'Switch'}</button>`}
        <button data-account-action="update"${disabled}>${account.isRefreshing ? 'Updating…' : 'Refresh'}</button>
        <button class="is-danger" data-account-action="forget"${disabled}>Forget</button>
      </div>
    </section>`;
  }

  function usageMarkup(line) {
    const escaped = domUtils.escapeHTML(line);
    const separator = line.indexOf(': ');
    if (separator < 0) return `<div class="codex-accounts-usage-note">${escaped}</div>`;
    return `<div class="codex-accounts-usage">
      <span>${domUtils.escapeHTML(line.slice(0, separator))}:</span>
      <span>${domUtils.escapeHTML(line.slice(separator + 2))}</span>
    </div>`;
  }

  function usesLightHostSurface(trigger) {
    let element = trigger.closest('[role="menu"]') || trigger;
    while (element) {
      const match = getComputedStyle(element).backgroundColor.match(
        /^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/,
      );
      if (match && (match[4] === undefined || Number(match[4]) > 0)) {
        const [red, green, blue] = match.slice(1, 4).map(Number);
        // A menu surface is light when its perceived brightness is above the
        // midpoint. Reading the rendered host avoids relying on private CSS
        // class names that can change between Codex releases.
        return (red * 0.2126 + green * 0.7152 + blue * 0.0722) > 128;
      }
      element = element.parentElement;
    }
    return !matchMedia('(prefers-color-scheme: dark)').matches;
  }

  function renderPanel() {
    const panel = document.getElementById(panelID);
    if (!panel) return;
    const disabled = snapshot.isBusy || actions.length ? ' disabled' : '';
    panel.innerHTML = `<header><strong>Accounts</strong><button data-account-close aria-label="Close accounts">×</button></header>
      <div class="codex-accounts-list">${snapshot.accounts.length
        ? snapshot.accounts.map(accountMarkup).join('')
        : '<div class="codex-accounts-empty">No saved accounts yet.</div>'}</div>
      ${actionProgress || snapshot.statusMessage ? `<div class="codex-accounts-status">${domUtils.escapeHTML(actionProgress || snapshot.statusMessage)}</div>` : ''}
      <footer>
        <button data-account-global="save"${disabled}><span>✓</span>Save current account</button>
        <button data-account-global="add"${disabled}><span>＋</span>Add another account</button>
        ${snapshot.accounts.length > 1 ? `<button data-account-global="update-all"${disabled}><span>↻</span>Refresh other accounts</button>` : ''}
      </footer>`;
    panel.querySelector('[data-account-close]')?.addEventListener('click', closePanel);
    panel.querySelectorAll('[data-account-action]').forEach((button) => {
      const handleAction = (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (button.dataset.accountHandled === 'true') return;
        const id = button.closest('[data-account-id]')?.dataset.accountId;
        const action = button.dataset.accountAction;
        if (action === 'forget' && !window.confirm('Forget this saved account?')) return;
        button.dataset.accountHandled = 'true';
        queue(action === 'update'
          ? 'updateUsage'
          : action === 'switch'
            ? 'switchAccount'
            : action === 'sign-in'
              ? 'addAccount'
              : 'forgetAccount', id);
      };
      // Queue on pointerdown before Codex's profile-menu dismissal can cancel
      // the subsequent click. Keep click for keyboard activation.
      button.addEventListener('pointerdown', handleAction);
      button.addEventListener('click', handleAction);
    });
    panel.querySelectorAll('[data-account-global]').forEach((button) => button.addEventListener('click', () => {
      const kinds = { save: 'saveCurrentAccount', add: 'addAccount', 'update-all': 'refreshInactiveUsage' };
      if (button.dataset.accountGlobal === 'add'
          && !window.confirm('Codex will restart signed out so you can add another account. Continue?')) return;
      queue(kinds[button.dataset.accountGlobal]);
    }));
  }

  function openPanel(trigger) {
    closePanel();
    const panel = document.createElement('div');
    panel.id = panelID;
    panel.classList.toggle('is-light', usesLightHostSurface(trigger));
    const rect = trigger.closest('[role="menu"]')?.getBoundingClientRect()
      || trigger.getBoundingClientRect();
    const inset = 12;
    const width = Math.min(328, Math.max(0, innerWidth - inset * 2));
    const preferredLeft = rect.right + width + 20 <= innerWidth
      ? rect.right + 8
      : rect.left - width - 8;
    panel.style.width = `${width}px`;
    panel.style.left = `${Math.min(
      Math.max(inset, preferredLeft),
      Math.max(inset, innerWidth - width - inset),
    )}px`;
    panel.style.bottom = `${Math.max(12, innerHeight - rect.bottom)}px`;
    // The panel lives outside Codex's profile-menu portal. Prevent the host's
    // click-away handler from treating presses inside this overlay as outside
    // profile-menu interactions and removing the controls before `click` fires.
    panel.addEventListener('pointerdown', (event) => event.stopPropagation());
    panel.addEventListener('mousedown', (event) => event.stopPropagation());
    document.body.append(panel);
    renderPanel();
    outsidePointerHandler = (event) => {
      if (!panel.contains(event.target) && !trigger.contains(event.target)) closePanel();
    };
    escapeHandler = (event) => {
      if (event.key === 'Escape') closePanel();
    };
    const handler = outsidePointerHandler;
    outsidePointerTimer = setTimeout(() => {
      outsidePointerTimer = undefined;
      if (outsidePointerHandler === handler) {
        document.addEventListener('pointerdown', handler, true);
      }
    }, 0);
    document.addEventListener('keydown', escapeHandler, true);
  }

  function closePanel() {
    document.getElementById(panelID)?.remove();
    if (outsidePointerTimer !== undefined) {
      clearTimeout(outsidePointerTimer);
      outsidePointerTimer = undefined;
    }
    if (outsidePointerHandler) {
      document.removeEventListener('pointerdown', outsidePointerHandler, true);
      outsidePointerHandler = undefined;
    }
    if (escapeHandler) {
      document.removeEventListener('keydown', escapeHandler, true);
      escapeHandler = undefined;
    }
  }

  function mountTrigger() {
    if (document.querySelector(`[${triggerAttribute}]`)) return;
    const host = codexUIContracts.profileMenu();
    if (!host) return;
    const anchor = codexUIContracts.profileMenuAccountAnchor(host);
    const insertionParent = anchor?.parentElement;
    if (!anchor || !insertionParent || !host.contains(insertionParent)) return;
    const trigger = anchor.cloneNode(true);
    if (trigger instanceof HTMLButtonElement) trigger.type = 'button';
    trigger.setAttribute(triggerAttribute, '');
    trigger.querySelectorAll('kbd').forEach((shortcut) => shortcut.remove());
    const label = [...trigger.querySelectorAll('span')].find((span) => (
      span.textContent.trim() === 'Settings'
    ));
    if (label) {
      label.textContent = 'Accounts';
      trigger.querySelector('svg')?.replaceWith(accountIcon());
      const row = label.parentElement;
      const chevron = document.createElement('span');
      chevron.setAttribute('aria-hidden', 'true');
      chevron.textContent = '›';
      row?.append(chevron);
    } else {
      trigger.innerHTML = '<span>Accounts</span><span aria-hidden="true">›</span>';
    }
    trigger.addEventListener('pointerdown', (event) => event.stopPropagation());
    trigger.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      openPanel(trigger);
    });
    insertionParent.insertBefore(trigger, anchor);
  }

  function accountIcon() {
    const template = document.createElement('template');
    template.innerHTML = `<svg width="24" height="24" viewBox="0 0 24 24" fill="none"
      xmlns="http://www.w3.org/2000/svg"
      class="icon-xs shrink-0 opacity-75 group-focus:opacity-100 group-hover:opacity-100">
      <path d="M15.5 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM8.5 12a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM15.5 13c-3.1 0-5.5 1.8-5.5 4v2h11v-2c0-2.2-2.4-4-5.5-4ZM8.5 14C5.5 14 3 15.7 3 18v1h5v-2c0-1.1.4-2.1 1.2-3H8.5Z" fill="currentColor"/>
    </svg>`;
    return template.content.firstElementChild;
  }

  function handleMutations(records) {
    const triggerWasRemoved = records.some((record) => (
      [...record.removedNodes].some((node) => (
        node.nodeType === Node.ELEMENT_NODE
          && (node.matches?.(`[${triggerAttribute}]`) || node.querySelector?.(`[${triggerAttribute}]`))
      ))
    ));
    if (triggerWasRemoved) {
      if (!retainPanelUntilActionCompletes) closePanel();
    }
    const shouldMountTrigger = !document.querySelector(`[${triggerAttribute}]`) && records.some((record) => (
      (record.type === 'attributes' ? [record.target] : [...record.addedNodes]).some((node) => {
        if (node.nodeType !== Node.ELEMENT_NODE) return false;
        return containsMenuNode(node);
      })
    ));
    if (shouldMountTrigger) mountTrigger();
  }

  function containsMenuNode(root) {
    // Ignore our own UI, but inspect the complete added subtree. Codex can
    // portal its profile menu through deep wrappers or use plain buttons.
    if (root.closest?.(`#${panelID}`)) return false;
    const selector = '[role="menu"], [role="menuitem"], button';
    return root.matches?.(selector) || (root.childElementCount > 0 && Boolean(root.querySelector?.(selector)));
  }

  function applySnapshot(next) {
    const candidate = next || snapshot;
    const candidateFingerprint = JSON.stringify(candidate);
    const changed = candidateFingerprint !== snapshotFingerprint;
    const hadActionProgress = actionProgress !== null;
    snapshot = candidate;
    snapshotFingerprint = candidateFingerprint;
    // The native action has completed once its resulting snapshot arrives.
    retainPanelUntilActionCompletes = false;
    actionProgress = null;
    mountTrigger();
    if (changed || hadActionProgress) renderPanel();
    return true;
  }

  function observeMutations() {
    // Keep a stable root: Codex removes the entire menu portal on close.
    // An observer attached inside that portal cannot see its own removal or
    // the next opening, leaving Accounts dependent on native refresh polling.
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['hidden', 'style', 'class', 'role'],
    });
  }

  function mount() {
    if (!observer) {
      observer = new MutationObserver(handleMutations);
      observeMutations();
    }
    mountTrigger();
  }

  function unmount() {
    observer?.disconnect();
    observer = undefined;
    document.querySelector(`[${triggerAttribute}]`)?.remove();
    closePanel();
  }

  return { applySnapshot, takeNextAction, mount, unmount };
})();
