const sidebarProjectGitIndicators = (() => {
  const contract = codexUIContracts.sidebarProjects;
  const labels = {
    uncommittedChanges: 'Uncommitted changes',
    unpushedCommits: 'Unpushed commits',
    uncommittedChangesAndUnpushedCommits: 'Uncommitted changes and unpushed commits',
  };
  let statuses = new Map();
  let hiddenPaths = new Set();
  let sidebar;
  let observer;

  function updateRows() {
    sidebar?.querySelectorAll(contract.selector).forEach(row => {
      const { name } = contract.metadata(row);
      const path = contract.localPath(row);
      const status = hiddenPaths.has(path) ? null : statuses.get(path);
      const label = row.querySelector('[data-marquee-text]');
      let marker = row.querySelector('[data-codex-project-git-status]');
      if (!status || !label) { marker?.remove(); return; }
      if (!marker) {
        marker = document.createElement('span');
        marker.setAttribute('data-codex-project-git-status', '');
        marker.setAttribute('role', 'status');
        marker.innerHTML = dashboardIcons.render('gitChanges');
      }
      // Keep the status outside the host's clipped, animated project-name wrapper.
      const colourButton = row.querySelector('[data-codex-project-colour]');
      if (marker.parentElement !== row || (colourButton && marker.nextElementSibling !== colourButton)) {
        row.insertBefore(marker, colourButton);
      }
      const description = `${name || 'Project'}: ${status}`;
      for (const attribute of ['aria-label', 'title']) {
        if (marker.getAttribute(attribute) !== description) marker.setAttribute(attribute, description);
      }
    });
  }

  function applyThreads(threads) {
    statuses = new Map();
    threads.forEach(thread => {
      const status = labels[thread.projectGitStatus];
      if (thread.projectGroupPath && status && !statuses.has(thread.projectGroupPath)) {
        statuses.set(thread.projectGroupPath, status);
      }
    });
    updateRows();
  }

  function setHiddenPaths(paths) {
    hiddenPaths = new Set(paths);
    updateRows();
  }

  function mount() {
    const nextSidebar = codexHost.sidebar();
    if (sidebar !== nextSidebar) {
      observer?.disconnect();
      sidebar = nextSidebar;
      observer = new MutationObserver(records => {
        if (contract.changedIn(records) || records.some(record =>
          record.target instanceof Element && record.target.closest(contract.selector))) updateRows();
      });
      if (sidebar) observer.observe(sidebar, { childList: true, subtree: true,
        attributes: true, attributeFilter: contract.observedAttributes });
    }
    updateRows();
  }

  function destroy() {
    observer?.disconnect();
    observer = undefined;
    sidebar = undefined;
    statuses.clear();
    hiddenPaths.clear();
    document.querySelectorAll('[data-codex-project-git-status]').forEach(marker => marker.remove());
  }

  return { applyThreads, setHiddenPaths, mount, destroy };
})();
