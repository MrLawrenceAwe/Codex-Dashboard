function createPushControls() {
  const changes = new Map();
  const blockedEvents = ['pointerdown', 'mousedown', 'click', 'keydown', 'cmdk-item-select'];
  let observer;
  let context;
  let generation = 0;
  let hasRemote = null;
  let lastState = 'waiting';

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
      context = usable ? next : null;
      hasRemote = null;
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
      restore();
      hasRemote = null;
      lastState = 'incompatible';
      return;
    }
    lastState = 'compatible';
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
      state: lastState,
      requestID: generation,
      path: context?.compatible ? context.path : null,
    };
  }

  function applyRemote(requestID, value) {
    sync();
    if (!context?.compatible || requestID !== generation) return false;
    hasRemote = typeof value === 'boolean' ? value : null;
    sync();
    return true;
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
    observer?.disconnect();
    observer = undefined;
    blockedEvents.forEach(type => document.removeEventListener(type, block, true));
    restore();
    context = undefined;
    hasRemote = null;
  }

  return { start, destroy, read, applyRemote };
}
