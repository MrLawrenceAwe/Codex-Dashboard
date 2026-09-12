const dashboardLifecycle = (() => {
  const navigationEvents = ['pointerdown', 'mousedown', 'click', 'keydown'];
  const routeEvents = ['message', 'popstate', 'hashchange'];
  let hooks;
  let structureObserver;
  let sidebarObserver;
  let composerObserver;
  let resizeObserver;
  let observedSidebar;
  let observedStructureRoot;
  let observedMutationSidebar;
  let observedComposerRoot;
  let repairFrame;
  let pendingUnreadSync = false;
  let pendingHostRebind = false;

  function handleNavigation(event) {
    if (event.type === 'message') {
      if (event.data?.type === 'navigate-to-route') {
        if (hooks.isOpen()) hooks.close();
        scheduleRepair({ rebindHosts: true });
      }
      return;
    }
    if (event.type === 'popstate' || event.type === 'hashchange') {
      if (hooks.isOpen()) hooks.close();
      scheduleRepair({ rebindHosts: true });
      return;
    }
    if (event.type === 'keydown') {
      const opensNewChat = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'n';
      if (hooks.isOpen() && opensNewChat) hooks.close();
      return;
    }
    const target = event.target instanceof Element ? event.target : null;
    if (target?.closest(`#${dashboardElements.elementIDs.taskNavButton}`)) {
      event.preventDefault();
      event.stopPropagation();
      if (event.type === 'click') hooks.openTasks();
      return;
    }
    if (target?.closest(`#${dashboardElements.elementIDs.todoNavButton}`)) {
      event.preventDefault();
      event.stopPropagation();
      if (event.type === 'click') hooks.openTodos();
      return;
    }
    if (event.type === 'click' && target?.closest('aside')) {
      if (hooks.isOpen()) hooks.close();
      scheduleRepair({ rebindHosts: true });
    }
  }

  function syncContentInset() {
    const sidebar = codexHost.sidebar();
    const pageHost = codexHost.pageHost();
    const sidebarRect = sidebar?.getBoundingClientRect();
    const hostRect = pageHost?.getBoundingClientRect();
    const hostScale = pageHost?.offsetWidth > 0 ? hostRect.width / pageHost.offsetWidth : 1;
    const width = sidebarRect && hostRect && Number.isFinite(hostScale) && hostScale > 0
      ? Math.max(0, (sidebarRect.right - hostRect.left) / hostScale)
      : 0;
    document.documentElement.style.setProperty(
      '--codex-dashboard-content-left',
      `${Math.round(width)}px`,
    );
  }

  function observeSidebarSize() {
    const sidebar = codexHost.sidebar();
    if (!resizeObserver || sidebar === observedSidebar) return;
    resizeObserver.disconnect();
    if (sidebar) resizeObserver.observe(sidebar);
    observedSidebar = sidebar;
  }

  function attachPage() {
    const pageHost = codexHost.pageHost();
    [dashboardElements.elementIDs.taskPage, dashboardElements.elementIDs.todoPage].forEach((id) => {
      const page = document.getElementById(id);
      if (page && pageHost && page.parentElement !== pageHost) pageHost.append(page);
    });
  }

  function composerRoot() {
    const composer = codexUIContracts.composer();
    return composer?.closest('form') || composer?.parentElement || null;
  }

  function observeHosts() {
    const structureRoot = codexHost.pageHost();
    if (structureObserver && structureRoot !== observedStructureRoot) {
      structureObserver.disconnect();
      if (structureRoot) structureObserver.observe(structureRoot, { childList: true, subtree: true });
      observedStructureRoot = structureRoot;
    }
    const sidebar = codexHost.sidebar();
    if (sidebarObserver && sidebar !== observedMutationSidebar) {
      sidebarObserver.disconnect();
      if (sidebar) sidebarObserver.observe(sidebar, { childList: true, subtree: true });
      observedMutationSidebar = sidebar;
    }
    const root = composerRoot();
    if (composerObserver && root !== observedComposerRoot) {
      composerObserver.disconnect();
      if (root) composerObserver.observe(root, { childList: true, subtree: true });
      observedComposerRoot = root;
    }
  }

  function scheduleRepair({ syncUnread = false, rebindHosts = false } = {}) {
    pendingUnreadSync ||= syncUnread;
    pendingHostRebind ||= rebindHosts;
    if (repairFrame !== undefined) return;
    repairFrame = requestAnimationFrame(() => {
      repairFrame = undefined;
      const shouldSyncUnread = pendingUnreadSync;
      const shouldRebindHosts = pendingHostRebind;
      pendingUnreadSync = false;
      pendingHostRebind = false;
      mountPagesAndNavigation();
      observeSidebarSize();
      if (shouldRebindHosts) {
        observeHosts();
        sidebarProjectHighlights.mount();
        promptLauncher.scheduleSync();
      }
      if (shouldSyncUnread && hooks.syncUnread()) hooks.requestRender();
    });
  }

  function containsDashboardElement(node) {
    if (!(node instanceof Element)) return false;
    return Object.values(dashboardElements.elementIDs).some((id) => (
      node.id === id || Boolean(node.querySelector(`#${id}`))
    ));
  }

  function handleStructureMutations(records) {
    const dashboardWasRemoved = records.some((record) => (
      [...record.removedNodes].some(containsDashboardElement)
    ));
    const dashboardElementIsMissing = [
      dashboardElements.elementIDs.taskPage,
      dashboardElements.elementIDs.todoPage,
      dashboardElements.elementIDs.taskNavButton,
      dashboardElements.elementIDs.todoNavButton,
    ].some((id) => !document.getElementById(id));
    if (!dashboardWasRemoved && !dashboardElementIsMissing && observedStructureRoot?.isConnected) return;
    scheduleRepair({ rebindHosts: true });
  }

  function containsThreadRow(node) {
    if (!(node instanceof Element)) return false;
    return node.matches('[data-app-action-sidebar-thread-id]')
      || Boolean(node.querySelector('[data-app-action-sidebar-thread-id]'));
  }

  function handleSidebarMutations(records) {
    const threadRowsChanged = records.some((record) => {
      const target = record.target instanceof Element ? record.target : record.target?.parentElement;
      if (target?.closest('[data-app-action-sidebar-thread-id]')) return true;
      return [...record.addedNodes, ...record.removedNodes].some(containsThreadRow);
    });
    if (threadRowsChanged) scheduleRepair({ syncUnread: true });
  }

  function handleComposerMutations() {
    if (composerRoot() !== observedComposerRoot) {
      scheduleRepair({ rebindHosts: true });
      return;
    }
    promptLauncher.scheduleSync();
  }

  function mountPagesAndNavigation() {
    // Feature mount methods are idempotent and own their element-presence checks.
    hooks.mountPage();
    hooks.mountNavigation();
    attachPage();
    hooks.applyVisibility();
  }

  function ensureMounted(nextHooks) {
    hooks = nextHooks;
    if (!document.body) return false;
    if (!document.getElementById(dashboardElements.elementIDs.style)) {
      const style = document.createElement('style');
      style.id = dashboardElements.elementIDs.style;
      style.textContent = DASHBOARD_CSS;
      document.head.append(style);
    }
    mountPagesAndNavigation();
    syncContentInset();
    sidebarProjectHighlights.start();
    promptLibrary.mount();
    accountPopover.mount();
    if (!structureObserver) {
      structureObserver = new MutationObserver(handleStructureMutations);
      sidebarObserver = new MutationObserver(handleSidebarMutations);
      composerObserver = new MutationObserver(handleComposerMutations);
      observeHosts();
      navigationEvents.forEach((type) => document.addEventListener(type, handleNavigation, true));
      routeEvents.forEach((type) => window.addEventListener(type, handleNavigation, true));
    }
    if (!resizeObserver && typeof ResizeObserver !== 'undefined') {
      resizeObserver = new ResizeObserver(syncContentInset);
      observeSidebarSize();
    }
    return Boolean(
      document.getElementById(dashboardElements.elementIDs.style)
        && document.getElementById(dashboardElements.elementIDs.taskPage)
        && document.getElementById(dashboardElements.elementIDs.taskNavButton)
        && document.getElementById(dashboardElements.elementIDs.todoPage)
        && document.getElementById(dashboardElements.elementIDs.todoNavButton)
    );
  }

  function destroy() {
    sidebarProjectHighlights.destroy();
    structureObserver?.disconnect();
    sidebarObserver?.disconnect();
    composerObserver?.disconnect();
    resizeObserver?.disconnect();
    if (repairFrame !== undefined) cancelAnimationFrame(repairFrame);
    navigationEvents.forEach((type) => document.removeEventListener(type, handleNavigation, true));
    routeEvents.forEach((type) => window.removeEventListener(type, handleNavigation, true));
    structureObserver = undefined;
    sidebarObserver = undefined;
    composerObserver = undefined;
    resizeObserver = undefined;
    observedSidebar = undefined;
    observedStructureRoot = undefined;
    observedMutationSidebar = undefined;
    observedComposerRoot = undefined;
    repairFrame = undefined;
    pendingUnreadSync = false;
    pendingHostRebind = false;
    promptLibrary.unmount();
    accountPopover.unmount();
    document.documentElement.classList.remove('codex-dashboard-open');
    document.documentElement.style.removeProperty('--codex-dashboard-content-left');
    Object.values(dashboardElements.elementIDs).forEach((id) => document.getElementById(id)?.remove());
  }

  return { destroy, ensureMounted };
})();
