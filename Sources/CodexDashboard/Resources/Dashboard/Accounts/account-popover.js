const accountPopover = (() => {
  const triggerAttribute = 'data-codex-accounts-trigger';
  const panelID = 'codex-accounts-panel';
  let snapshot = { accounts: [], activeAccountID: null, statusMessage: null, isBusy: false };
  let snapshotFingerprint = '';
  let observer;
  let outsidePointerHandler;
  let escapeHandler;
  const actions = [];

  function visibleAction(label) {
    return [...document.querySelectorAll('[role="menuitem"], button')].find((element) => (
      element.getClientRects().length > 0
        && (element.textContent.trim() === label || element.textContent.trim().startsWith(label))
    ));
  }

  function menuHost() {
    const logout = visibleAction('Log out');
    const settings = visibleAction('Settings');
    if (!logout || !settings) return null;
    const semanticMenu = logout.closest('[role="menu"]');
    if (semanticMenu) return semanticMenu;
    const sharedParent = logout.parentElement?.parentElement;
    return sharedParent && sharedParent.contains(settings) ? sharedParent : logout.parentElement;
  }

  function queue(kind, accountID = null) {
    if (snapshot.isBusy || actions.length) return;
    actions.push({ kind, accountID });
    renderPanel();
  }

  function pollState() {
    return JSON.stringify({
      isOpen: document.getElementById(panelID) !== null,
      action: actions.shift() || null,
    });
  }

  function accountMarkup(account) {
    const disabled = snapshot.isBusy || actions.length || account.isRefreshing ? ' disabled' : '';
    const initial = dashboardElements.escapeHTML(account.name.trim().slice(0, 1).toUpperCase() || '?');
    const usage = account.usageLines.map(usageMarkup).join('');
    return `<section class="codex-accounts-card" data-account-id="${account.id}">
      <div class="codex-accounts-heading">
        <span class="codex-accounts-avatar">${initial}</span>
        <strong>${dashboardElements.escapeHTML(account.name)}</strong>
        ${account.isActive ? '<span class="codex-accounts-active"><i></i>Active</span>' : ''}
      </div>
      <div class="codex-accounts-usage-list">${usage}</div>
      ${account.errorMessage ? `<div class="codex-accounts-error">${dashboardElements.escapeHTML(account.errorMessage)}</div>` : ''}
      <div class="codex-accounts-actions">
        ${account.isActive ? '' : `<button class="is-primary" data-account-action="switch"${disabled}>Switch</button>`}
        <button data-account-action="update"${disabled}>${account.isRefreshing ? 'Updating…' : 'Refresh'}</button>
        <button class="is-danger" data-account-action="forget"${disabled}>Forget</button>
      </div>
    </section>`;
  }

  function usageMarkup(line) {
    const escaped = dashboardElements.escapeHTML(line);
    const separator = line.indexOf(': ');
    if (separator < 0) return `<div class="codex-accounts-usage-note">${escaped}</div>`;
    return `<div class="codex-accounts-usage">
      <span>${dashboardElements.escapeHTML(line.slice(0, separator))}:</span>
      <span>${dashboardElements.escapeHTML(line.slice(separator + 2))}</span>
    </div>`;
  }

  function renderPanel() {
    const panel = document.getElementById(panelID);
    if (!panel) return;
    const disabled = snapshot.isBusy || actions.length ? ' disabled' : '';
    panel.innerHTML = `<header><strong>Accounts</strong><button data-account-close aria-label="Close accounts">×</button></header>
      <div class="codex-accounts-list">${snapshot.accounts.length
        ? snapshot.accounts.map(accountMarkup).join('')
        : '<div class="codex-accounts-empty">No saved accounts yet.</div>'}</div>
      ${snapshot.statusMessage ? `<div class="codex-accounts-status">${dashboardElements.escapeHTML(snapshot.statusMessage)}</div>` : ''}
      <footer>
        <button data-account-global="save"${disabled}><span>✓</span>Save current account</button>
        <button data-account-global="add"${disabled}><span>＋</span>Add another account</button>
        ${snapshot.accounts.length > 1 ? `<button data-account-global="update-all"${disabled}><span>↻</span>Refresh signed-out accounts</button>` : ''}
      </footer>`;
    panel.querySelector('[data-account-close]')?.addEventListener('click', closePanel);
    panel.querySelectorAll('[data-account-action]').forEach((button) => button.addEventListener('click', () => {
      const id = button.closest('[data-account-id]')?.dataset.accountId;
      const action = button.dataset.accountAction;
      if (action === 'forget' && !window.confirm('Forget this saved account?')) return;
      queue(action === 'update' ? 'updateUsage' : action === 'switch' ? 'switchAccount' : 'forgetAccount', id);
    }));
    panel.querySelectorAll('[data-account-global]').forEach((button) => button.addEventListener('click', () => {
      const kinds = { save: 'saveCurrentAccount', add: 'addAccount', 'update-all': 'updateSignedOutUsage' };
      if (button.dataset.accountGlobal === 'add'
          && !window.confirm('Codex will restart signed out so you can add another account. Continue?')) return;
      queue(kinds[button.dataset.accountGlobal]);
    }));
  }

  function openPanel(trigger) {
    closePanel();
    const panel = document.createElement('div');
    panel.id = panelID;
    const rect = trigger.closest('[role="menu"]')?.getBoundingClientRect()
      || trigger.getBoundingClientRect();
    const width = 328;
    panel.style.left = `${rect.right + width + 20 <= innerWidth
      ? rect.right + 8
      : Math.max(12, rect.left - width - 8)}px`;
    panel.style.bottom = `${Math.max(12, innerHeight - rect.bottom)}px`;
    document.body.append(panel);
    renderPanel();
    outsidePointerHandler = (event) => {
      if (!panel.contains(event.target) && !trigger.contains(event.target)) closePanel();
    };
    escapeHandler = (event) => {
      if (event.key === 'Escape') closePanel();
    };
    setTimeout(() => document.addEventListener('pointerdown', outsidePointerHandler, true), 0);
    document.addEventListener('keydown', escapeHandler, true);
  }

  function closePanel() {
    document.getElementById(panelID)?.remove();
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
    const host = menuHost();
    if (!host) return;
    const showPet = visibleAction('Show pet');
    const insertionParent = showPet?.parentElement;
    if (!showPet || !insertionParent || !host.contains(insertionParent)) return;
    const trigger = showPet.cloneNode(true);
    if (trigger instanceof HTMLButtonElement) trigger.type = 'button';
    trigger.setAttribute(triggerAttribute, '');
    const label = [...trigger.querySelectorAll('span')].find((span) => (
      span.textContent.trim() === 'Show pet'
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
    insertionParent.insertBefore(trigger, showPet);
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
    if (triggerWasRemoved) closePanel();
    const shouldRemount = records.some((record) => (
      [...record.addedNodes].some((node) => {
        if (node.nodeType !== Node.ELEMENT_NODE) return false;
        return containsMenuNode(node);
      })
      || triggerWasRemoved
    ));
    if (shouldRemount) mountTrigger();
  }

  function containsMenuNode(root) {
    const pending = [{ element: root, depth: 0 }];
    let inspected = 0;
    while (pending.length && inspected < 40) {
      const { element, depth } = pending.shift();
      inspected += 1;
      const role = element.getAttribute?.('role');
      if (role === 'menu' || role === 'menuitem') return true;
      if (depth >= 4) continue;
      [...element.children].forEach((child) => pending.push({ element: child, depth: depth + 1 }));
    }
    return false;
  }

  function applySnapshot(next) {
    const candidate = next || snapshot;
    const candidateFingerprint = JSON.stringify(candidate);
    const changed = candidateFingerprint !== snapshotFingerprint;
    snapshot = candidate;
    snapshotFingerprint = candidateFingerprint;
    mountTrigger();
    if (changed) renderPanel();
    return true;
  }

  function mount() {
    mountTrigger();
    if (!observer) {
      observer = new MutationObserver(handleMutations);
      observer.observe(document.body, { childList: true, subtree: true });
    }
  }

  function unmount() {
    observer?.disconnect();
    observer = undefined;
    document.querySelector(`[${triggerAttribute}]`)?.remove();
    closePanel();
  }

  return { applySnapshot, pollState, mount, unmount };
})();
