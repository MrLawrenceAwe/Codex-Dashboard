function createProjectViewerControls(findThread) {
  const projectContract = codexUIContracts.sidebarProjects;
  const headerSelector = '[data-app-shell-header-toolbar]';
  const buttonSelector = '[data-dashboard-viewer-control]';
  let headerButton;
  let observer;
  let pendingSync;

  function localPath(path) {
    return typeof path === 'string' && path.startsWith('/') ? path : null;
  }

  function currentCheckout() {
    return localPath(findThread(codexUIContracts.selectedThreadID())?.checkoutPath);
  }

  function makeButton(kind) {
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.dashboardViewerControl = kind;
    button.className = 'dashboard-viewer-control';
    button.innerHTML = dashboardIcons.render('project');
    if (kind === 'header') {
      const label = document.createElement('span');
      label.textContent = 'Project Viewer';
      button.append(label);
      button.title = 'Open Project Viewer';
      button.setAttribute('aria-label', button.title);
      button.addEventListener('click', () => {
        if (button.parentElement !== codexUIContracts.chatHeaderActionsHost()) return;
        const threadID = codexUIContracts.selectedThreadID();
        projectViewerLauncher.open(localPath(findThread(threadID)?.checkoutPath), { threadID });
      });
    }
    return button;
  }

  function sync() {
    const host = codexUIContracts.chatHeaderActionsHost();
    if (host && currentCheckout()) {
      headerButton ??= makeButton('header');
      if (headerButton.parentElement !== host) host.prepend(headerButton);
    } else {
      headerButton?.remove();
    }

    const sidebar = codexUIContracts.sidebar();
    for (const button of document.querySelectorAll('[data-dashboard-viewer-control="sidebar"]')) {
      const row = button.parentElement;
      if (!row?.matches(projectContract.selector) || !sidebar?.contains(row)
        || !localPath(projectContract.localPath(row))) button.remove();
    }
    for (const row of sidebar?.querySelectorAll(projectContract.selector) || []) {
      if (!localPath(projectContract.localPath(row))) continue;
      let button = row.querySelector(':scope > [data-dashboard-viewer-control="sidebar"]');
      if (!button) {
        button = makeButton('sidebar');
        row.append(button);
      }
      const label = `Open Project Viewer for ${projectContract.metadata(row).name || 'project'}`;
      if (button.title !== label) {
        button.title = label;
        button.setAttribute('aria-label', label);
      }
    }
  }

  function handleSidebarButton(event) {
    const button = event.target instanceof Element
      ? event.target.closest('[data-dashboard-viewer-control="sidebar"]') : null;
    if (!button) return;
    // Keep the row's navigation and disclosure handlers out of this action.
    event.stopImmediatePropagation();
    if (event.type === 'keydown') {
      if (event.key !== 'Enter' && event.key !== ' ') return;
      event.preventDefault();
      if (!event.repeat) button.click();
      return;
    }
    if (event.type !== 'click') return;
    event.preventDefault();
    const row = button.closest(projectContract.selector);
    const path = localPath(projectContract.localPath(row));
    if (path) projectViewerLauncher.open(path, { projectID: projectContract.metadata(row).id });
  }

  function scheduleSync() {
    if (pendingSync !== undefined) return;
    pendingSync = setTimeout(() => {
      pendingSync = undefined;
      sync();
    }, 0);
  }

  function handleMutations(records) {
    const structure = `${headerSelector}, ${projectContract.selector}, textarea, [contenteditable="true"]`;
    const containsHost = node => node instanceof Element
      && (node.matches(structure) || node.querySelector(structure));
    const affectsControls = record => {
      if (record.type === 'attributes') {
        return record.attributeName === 'aria-current'
          || projectContract.observedAttributes.includes(record.attributeName)
          || record.target.closest?.(headerSelector)
          || containsHost(record.target);
      }
      return record.target.closest?.(headerSelector)
        || record.target.closest?.(projectContract.selector)
        || [...record.addedNodes, ...record.removedNodes].some(containsHost)
        || [...record.removedNodes].some(node => node instanceof Element && node.matches(buttonSelector));
    };
    if (records.some(affectsControls)) scheduleSync();
  }

  const inputEvents = ['pointerdown', 'mousedown', 'click', 'keydown'];
  const navigationEvents = ['popstate', 'hashchange'];
  function handleRouteMessage(event) {
    if (event.data?.type === 'navigate-to-route') scheduleSync();
  }

  function mount() {
    if (!observer) {
      observer = new MutationObserver(handleMutations);
      observer.observe(document.body, { childList: true, subtree: true, attributes: true,
        attributeFilter: ['aria-current', 'aria-hidden', 'hidden', ...projectContract.observedAttributes] });
      inputEvents.forEach(type => document.addEventListener(type, handleSidebarButton, true));
      navigationEvents.forEach(type => window.addEventListener(type, scheduleSync));
      window.addEventListener('message', handleRouteMessage);
    }
    sync();
  }

  function destroy() {
    observer?.disconnect();
    observer = undefined;
    clearTimeout(pendingSync);
    pendingSync = undefined;
    inputEvents.forEach(type => document.removeEventListener(type, handleSidebarButton, true));
    navigationEvents.forEach(type => window.removeEventListener(type, scheduleSync));
    window.removeEventListener('message', handleRouteMessage);
    document.querySelectorAll(buttonSelector).forEach(button => button.remove());
    headerButton = undefined;
  }

  return { mount, sync, destroy };
}
