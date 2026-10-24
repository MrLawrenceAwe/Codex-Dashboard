function createPushControls() {
  const changes = new Map();
  const blockedEvents = ['pointerdown', 'mousedown', 'click', 'keydown', 'cmdk-item-select'];
  let observer;
  let context;
  let generation = 0;
  let hasRemote = null;
  let lastState = 'waiting';
  const remoteCache = new Map();
  const remoteFreshness = 5000;
  let unsubscribe;
  let pendingRemote;
  let lastRequestedGeneration;
  let lastRequestedAt = 0;
  let remoteFailure = false;

  function cancelRemote() {
    if (!pendingRemote) return;
    clearTimeout(pendingRemote.timer);
    const id = pendingRemote.id;
    pendingRemote = undefined;
    try {
      Promise.resolve(window.electronBridge?.sendWorkerMessageFromView?.('git', {
        type: 'worker-request-cancel', workerId: 'git', id,
      })).catch(() => {});
    } catch { /* A changed bridge must not prevent teardown or navigation. */ }
  }

  function finishRemote(id, value) {
    if (id !== pendingRemote?.id) return;
    const request = pendingRemote;
    clearTimeout(request.timer);
    pendingRemote = undefined;
    // Replies are scoped to the dialog and selected repository, including a
    // dialog closed and reopened before an earlier request completes.
    if (request.generation !== generation || request.path !== context?.path) return;
    hasRemote = value;
    remoteFailure = value === null;
    remoteCache.delete(request.path);
    if (value !== null) {
      remoteCache.set(request.path, { value, checkedAt: Date.now() });
      if (remoteCache.size > 64) remoteCache.delete(remoteCache.keys().next().value);
    }
    sync();
  }

  function receiveRemote(message) {
    if (!pendingRemote || message?.type !== 'worker-response' || message.workerId !== 'git'
      || message.response?.id !== pendingRemote?.id) return;
    const response = message.response;
    const metadata = response.result?.type === 'ok' ? response.result.value : null;
    let value = null;
    if (response.method === 'git-context'
      && ['complete', 'partial'].includes(metadata?.status) && Array.isArray(metadata.remotes)) {
      if (metadata.remotes.length > 0) value = true;
      else if (metadata.remotesOmitted === 0) value = false;
    }
    finishRemote(response.id, value);
  }

  function requestRemote() {
    if (pendingRemote || (lastRequestedGeneration === generation
      && Date.now() - lastRequestedAt < remoteFreshness)) return;
    lastRequestedGeneration = generation;
    lastRequestedAt = Date.now();
    const id = `dashboard-push-${crypto.randomUUID()}`;
    pendingRemote = { id, generation, path: context.path,
      timer: setTimeout(() => finishRemote(id, null), 2000) };
    if (!unsubscribe || typeof window.electronBridge?.sendWorkerMessageFromView !== 'function') {
      finishRemote(id, null);
      return;
    }
    try {
      Promise.resolve(window.electronBridge.sendWorkerMessageFromView('git', {
        type: 'worker-request', workerId: 'git', request: {
          id, method: 'git-context', enqueuedAtMs: Date.now(),
          params: { cwd: context.path, hostConfig: context.hostConfig,
            operationSource: 'dashboard_push_controls' },
        },
      })).catch(() => finishRemote(id, null));
    } catch { finishRemote(id, null); }
  }

  function restore() {
    for (const [item, attributes] of changes) {
      for (const [name, { previous, applied }] of attributes) {
        // Preserve an intervening host update rather than restoring stale values.
        if (item.getAttribute(name) !== applied) continue;
        const hostValue = ['aria-disabled', 'data-disabled'].includes(name)
          ? codexUIContracts.pushControlHostAttribute(item, name) : undefined;
        const restored = hostValue === undefined ? previous : hostValue;
        if (restored === null) item.removeAttribute(name);
        else item.setAttribute(name, restored);
      }
    }
    changes.clear();
  }

  function setAttribute(item, name, applied) {
    let attributes = changes.get(item);
    if (!attributes) changes.set(item, attributes = new Map());
    if (item.getAttribute(name) === applied) return;
    attributes.set(name, { previous: item.getAttribute(name), applied });
    item.setAttribute(name, applied);
  }

  function sync() {
    const next = codexUIContracts.pushControls();
    const threadID = next?.local ? codexUIContracts.selectedThreadID() : null;
    const usable = next?.local && next.threadID === threadID;
    if (!usable || !context || next.dialog !== context.dialog
      || next.path !== context.path || next.threadID !== context.threadID) {
      restore();
      cancelRemote();
      context = usable ? next : null;
      const cached = context && remoteCache.get(context.path);
      hasRemote = cached && Date.now() - cached.checkedAt < remoteFreshness ? cached.value : null;
      remoteFailure = false;
      generation += 1;
    } else {
      context = next;
    }
    if (!context) {
      if (next?.unsupported) lastState = 'incompatible';
      return;
    }
    if (!context.compatible) {
      if (lastState !== 'incompatible') generation += 1;
      cancelRemote();
      restore();
      hasRemote = null;
      lastState = 'incompatible';
      return;
    }
    lastState = 'compatible';
    requestRemote();
    // Remove ownership of items replaced by Codex during a render.
    if ([...changes.keys()].some(item => !context.items.includes(item))) restore();
    if (hasRemote !== false) { restore(); return; }
    for (const item of context.items.slice(1)) {
      setAttribute(item, 'data-dashboard-no-remote', 'true');
      setAttribute(item, 'aria-disabled', 'true');
      setAttribute(item, 'data-disabled', 'true');
      setAttribute(item, 'title', 'No Git remote is configured for this repository.');
    }
  }

  function read() {
    sync();
    return {
      state: remoteFailure && context?.compatible ? 'remote-unavailable' : lastState,
      path: context?.compatible ? context.path : null,
    };
  }

  function block(event) {
    sync();
    if (hasRemote !== false || !context?.compatible) return;
    const target = event.target instanceof Element ? event.target : null;
    let item = target?.closest('[cmdk-item]');
    if (event.type === 'keydown') {
      if (event.key !== 'Enter' || !context.dialog.contains(target)) return;
      // Cmd+Enter can originate in the message field. cmdk's selected option
      // determines the action, so check it even when focus is outside the list.
      item = context.root.querySelector('[cmdk-item][aria-selected="true"], [cmdk-item][data-selected="true"]');
    }
    if (!context.items.slice(1).includes(item)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  function start() {
    if (observer) return;
    if (typeof window.electronBridge?.subscribeToWorkerMessages === 'function') {
      try { unsubscribe = window.electronBridge.subscribeToWorkerMessages('git', receiveRemote); }
      catch { unsubscribe = undefined; }
    }
    observer = new MutationObserver(records => {
      const containsDialog = node => node instanceof Element && (
        node.matches('[role="dialog"]')
          || (node.firstElementChild && node.querySelector('[role="dialog"]'))
      );
      if (context || records.some(record => record.type === 'attributes'
        ? record.target.matches('[role="dialog"]')
        : [...record.addedNodes, ...record.removedNodes].some(containsDialog))) sync();
    });
    observer.observe(document.body, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['aria-disabled', 'data-disabled', 'data-value', 'role'],
    });
    blockedEvents.forEach(type => document.addEventListener(type, block, true));
    sync();
  }

  function destroy() {
    cancelRemote();
    unsubscribe?.();
    unsubscribe = undefined;
    remoteCache.clear();
    observer?.disconnect();
    observer = undefined;
    blockedEvents.forEach(type => document.removeEventListener(type, block, true));
    restore();
    context = undefined;
    hasRemote = null;
  }

  return { start, destroy, read };
}
