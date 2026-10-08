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
  let queuedActionTimer;
  let queuedActionDeadline = 0;
  let queuedAction = null;
  let countdownTimer;
  const countdownID = 'codex-usage-blockage';
  let countdownCollapsed = false;
  let countdownPosition = null;
  let countdownResizeHandler;

  function positionCountdown(notice, left, top) {
    const rect = notice.getBoundingClientRect();
    countdownPosition = {
      left: Math.max(12, Math.min(left, innerWidth - rect.width - 12)),
      top: Math.max(12, Math.min(top, innerHeight - rect.height - 12)),
    };
    notice.style.right = 'auto';
    notice.style.left = `${countdownPosition.left}px`;
    notice.style.top = `${countdownPosition.top}px`;
  }

  function removeCountdown() {
    if (countdownResizeHandler) window.removeEventListener('resize', countdownResizeHandler);
    countdownResizeHandler = undefined;
    document.getElementById(countdownID)?.remove();
    if (countdownTimer !== undefined) clearInterval(countdownTimer);
    countdownTimer = undefined;
  }

  function setupCountdown(notice) {
    notice.innerHTML = `<header class="codex-usage-reset-header" title="Drag to move">
      <strong data-reset-title></strong>
      <button type="button" data-reset-toggle aria-controls="codex-usage-reset-details"></button>
      </header><div data-reset-countdown role="timer" aria-live="off"></div>
      <div id="codex-usage-reset-details"><div data-reset-date></div>
      <div data-reset-status></div></div>`;
    const toggle = notice.querySelector('[data-reset-toggle]');
    toggle.addEventListener('click', () => {
      countdownCollapsed = !countdownCollapsed;
      renderCountdown();
    });
    const header = notice.querySelector('header');
    let drag = null;
    header.addEventListener('pointerdown', (event) => {
      if (event.button !== 0 || event.target.closest('button')) return;
      const rect = notice.getBoundingClientRect();
      drag = { pointerID: event.pointerId, x: event.clientX - rect.left, y: event.clientY - rect.top };
      header.setPointerCapture(event.pointerId);
      notice.classList.add('is-dragging');
      event.preventDefault();
    });
    header.addEventListener('pointermove', (event) => {
      if (drag?.pointerID !== event.pointerId) return;
      positionCountdown(notice, event.clientX - drag.x, event.clientY - drag.y);
    });
    const endDrag = () => {
      drag = null;
      notice.classList.remove('is-dragging');
    };
    header.addEventListener('pointerup', endDrag);
    header.addEventListener('pointercancel', endDrag);
    header.addEventListener('lostpointercapture', endDrag);
    countdownResizeHandler = () => {
      const rect = notice.getBoundingClientRect();
      positionCountdown(notice, rect.left, rect.top);
    };
    window.addEventListener('resize', countdownResizeHandler);
  }

  function resetCountdown(deadline) {
    const seconds = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const remainder = seconds % 60;
    return [days ? `${days}d` : '', hours ? `${hours}h` : '',
      minutes ? `${minutes}m` : '', `${remainder}s`].filter(Boolean).join(' ');
  }

  function renderCountdown() {
    const blockage = snapshot.usageBlockage;
    if (!blockage?.windows.length) {
      removeCountdown();
      return;
    }
    let notice = document.getElementById(countdownID);
    if (!notice) {
      notice = document.createElement('section');
      notice.id = countdownID;
      notice.setAttribute('aria-label', 'Codex usage reset countdown');
      document.body.append(notice);
      setupCountdown(notice);
    }
    notice.classList.toggle('is-light', usesLightHostSurface(document.querySelector('main') || document.body));
    const windows = blockage.windows;
    const deadlines = windows.map((window) => window.resetsAtMilliseconds);
    const hasAllDeadlines = deadlines.every((deadline) => Number.isFinite(deadline));
    const latestReset = hasAllDeadlines ? Math.max(...deadlines) : null;
    const resetDue = latestReset !== null && latestReset <= Date.now();
    const title = resetDue ? 'Reset due — awaiting usage update'
      : blockage.isStale ? 'Last known allowance depleted' : 'Codex allowance depleted';
    const countdown = latestReset === null ? 'Reset time unavailable'
      : resetDue ? 'Awaiting usage update…' : `Available in ${resetCountdown(latestReset)}`;
    const absolute = latestReset !== null && !resetDue
      ? `Reset: ${new Date(latestReset).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })}` : '';
    // Update text in place so the ticking clock never steals focus from the collapse control.
    notice.classList.toggle('is-collapsed', countdownCollapsed);
    notice.querySelector('#codex-usage-reset-details').hidden = countdownCollapsed;
    const toggle = notice.querySelector('[data-reset-toggle]');
    toggle.setAttribute('aria-expanded', String(!countdownCollapsed));
    toggle.setAttribute('aria-label', countdownCollapsed ? 'Expand usage notice' : 'Collapse usage notice');
    toggle.title = countdownCollapsed ? 'Expand' : 'Collapse';
    toggle.innerHTML = countdownCollapsed
      ? '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="m4 6 4 4 4-4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>'
      : '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="m4 10 4-4 4 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    notice.querySelector('[data-reset-title]').textContent = title;
    notice.querySelector('[data-reset-countdown]').textContent = countdown;
    notice.querySelector('[data-reset-date]').textContent = absolute;
    notice.querySelector('[data-reset-date]').hidden = !absolute;
    const status = notice.querySelector('[data-reset-status]');
    status.textContent = blockage.isStale ? 'Usage may be stale.' : '';
    status.hidden = !blockage.isStale;
    const position = countdownPosition || notice.getBoundingClientRect();
    positionCountdown(notice, position.left, position.top);
    if (countdownTimer === undefined) countdownTimer = setInterval(renderCountdown, 1000);
  }

  function expireQueuedAction() {
    if (!queuedAction) return;
    queuedAction = null;
    queuedActionDeadline = 0;
    retainPanelUntilActionCompletes = false;
    actionProgress = null;
    snapshot = { ...snapshot, statusMessage: 'Account request could not reach the dashboard. Please try again.' };
    renderPanel();
    renderCountdown();
  }

  function queue(kind, accountID = null) {
    if (snapshot.isBusy || actionProgress || queuedAction) return;
    // Codex closes its profile menu for clicks inside our separate overlay,
    // removing the trigger along with it. Keep the account panel mounted until
    // native code publishes the action's resulting snapshot so failures (for
    // example, an account switch blocked by an active task) remain visible.
    retainPanelUntilActionCompletes = true;
    queuedAction = { kind, accountID };
    queuedActionDeadline = Date.now() + 15000;
    queuedActionTimer = setTimeout(expireQueuedAction, 15000);
    actionProgress = kind === 'addAccount'
      ? 'Sign-in request queued…'
      : 'Account request queued…';
    renderPanel();
    renderCountdown();
  }

  function takeQueuedAction() {
    if (queuedAction && Date.now() >= queuedActionDeadline) expireQueuedAction();
    if (queuedActionTimer !== undefined) clearTimeout(queuedActionTimer);
    queuedActionTimer = undefined;
    const action = queuedAction;
    queuedAction = null;
    if (action) {
      actionProgress = 'Request received. Checking Codex state…';
      renderPanel();
      renderCountdown();
    }
    return JSON.stringify(action);
  }

  function accountMarkup(account) {
    const disabled = snapshot.isBusy || actionProgress || queuedAction || account.isRefreshing ? ' disabled' : '';
    const initial = domUtils.escapeHTML(account.name.trim().slice(0, 1).toUpperCase() || '?');
    const usage = account.usageRows.map(usageMarkup).join('');
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
        <button data-account-action="update"${disabled}>${account.isRefreshing ? 'Refreshing usage…' : 'Refresh usage'}</button>
        <button class="is-danger" data-account-action="forget"${disabled}>Remove saved account</button>
      </div>
    </section>`;
  }

  function usageMarkup(row) {
    if (row.label == null) return `<div class="codex-accounts-usage-note">${domUtils.escapeHTML(row.value)}</div>`;
    return `<div class="codex-accounts-usage">
      <span>${domUtils.escapeHTML(row.label)}:</span>
      <span>${domUtils.escapeHTML(row.value)}</span>
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
    const disabled = snapshot.isBusy || actionProgress || queuedAction ? ' disabled' : '';
    panel.innerHTML = `<header><strong>Accounts</strong><button data-account-close aria-label="Close accounts">×</button></header>
      <div class="codex-accounts-list">${snapshot.accounts.length
        ? snapshot.accounts.map(accountMarkup).join('')
        : '<div class="codex-accounts-empty">No saved accounts yet.</div>'}</div>
      ${actionProgress || snapshot.statusMessage ? `<div class="codex-accounts-status">${domUtils.escapeHTML(actionProgress || snapshot.statusMessage)}</div>` : ''}
      <footer>
        <button data-account-global="save"${disabled}><span>✓</span>Save current account</button>
        <button data-account-global="add"${disabled}><span>＋</span>Add another account</button>
        ${snapshot.accounts.length > 1 ? `<button data-account-global="update-all"${disabled}><span>↻</span>Refresh other accounts’ usage</button>` : ''}
      </footer>`;
    panel.querySelector('[data-account-close]')?.addEventListener('click', closePanel);
    panel.querySelectorAll('[data-account-action]').forEach((button) => {
      const handleAction = (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (button.dataset.accountHandled === 'true') return;
        const id = button.closest('[data-account-id]')?.dataset.accountId;
        const action = button.dataset.accountAction;
        if (action === 'forget' && !window.confirm('Remove this saved account from this device?')) return;
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
    if (!queuedAction && !snapshot.isBusy) {
      retainPanelUntilActionCompletes = false;
      actionProgress = null;
    }
    mountTrigger();
    if (changed || hadActionProgress) renderPanel();
    renderCountdown();
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
    renderCountdown();
  }

  function unmount() {
    removeCountdown();
    if (queuedActionTimer !== undefined) clearTimeout(queuedActionTimer);
    queuedActionTimer = undefined;
    queuedAction = null;
    actionProgress = null;
    retainPanelUntilActionCompletes = false;
    observer?.disconnect();
    observer = undefined;
    document.querySelector(`[${triggerAttribute}]`)?.remove();
    closePanel();
  }

  return { applySnapshot, takeQueuedAction, mount, unmount };
})();
