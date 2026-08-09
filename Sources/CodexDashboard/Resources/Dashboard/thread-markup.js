const threadMarkup = (() => {
  function icon(name) {
    const paths = {
      threads: '<path d="M8 6h12M8 12h12M8 18h12M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
      project: '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h5l2 2H19.5A1.5 1.5 0 0 1 21 9.5v8A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"/>',
      arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
      search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/>',
      pin: '<path d="m9 3 6 0-1 6 3 3v2H7v-2l3-3zM12 14v7"/>',
      gitChanges: '<circle cx="6" cy="5" r="2"/><circle cx="18" cy="6" r="2"/><circle cx="6" cy="19" r="2"/><path d="M6 7v10M8 6h5a5 5 0 0 1 5 5v-3"/>',
      chevron: '<path d="m9 18 6-6-6-6"/>',
    };
    return `<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths[name]}</svg>`;
  }

  function formatRelativeTime(timestamp) {
    const seconds = Math.max(0, Math.round(Date.now() / 1000 - Number(timestamp || 0)));
    if (seconds < 60) return 'just now';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    return `${Math.floor(hours / 24)}d ago`;
  }

  function thread(thread, { showProject = false, isUnread = false } = {}) {
    return `
      <article class="dashboard-thread" data-run-state="${dashboardDOM.escapeHTML(thread.runState)}" data-unread="${String(isUnread)}" data-thread-id="${dashboardDOM.escapeHTML(thread.id)}">
        <div class="dashboard-status-dot" title="${dashboardDOM.escapeHTML(thread.runState)}"></div>
        <div class="dashboard-thread-copy">
          <div class="dashboard-thread-title-row">
            ${isUnread ? '<span class="dashboard-unread-dot" role="status" aria-label="Unread response" title="Unread response"></span>' : ''}
            <h2>${dashboardDOM.escapeHTML(thread.title)}</h2>
            ${thread.isPinned ? `<span class="dashboard-pin" title="Pinned">${icon('pin')}</span>` : ''}
          </div>
          <p>${dashboardDOM.escapeHTML(thread.preview || 'No preview available')}</p>
          <div class="dashboard-meta">
            ${showProject ? `<span>${dashboardDOM.escapeHTML(thread.projectName)}</span>` : ''}
            <span>${formatRelativeTime(thread.recencyTimestamp)}</span>
            ${thread.model ? `<span>${dashboardDOM.escapeHTML(thread.model)}</span>` : ''}
          </div>
        </div>
        <div class="dashboard-thread-actions">
          ${thread.runState === 'running' ? '<span class="dashboard-running-spinner" role="status" aria-label="Running" title="Running"></span>' : ''}
          <button type="button" data-open-thread="${dashboardDOM.escapeHTML(thread.id)}">Open ${icon('arrow')}</button>
        </div>
      </article>`;
  }

  function list(visibleThreads, { viewMode, collapsedProjects, isUnread }) {
    if (viewMode === 'recent') {
      return [...visibleThreads]
        .sort((left, right) => Number(right.recencyTimestamp || 0) - Number(left.recencyTimestamp || 0))
        .map((item) => thread(item, { showProject: true, isUnread: isUnread(item) }))
        .join('');
    }
    const groups = new Map();
    visibleThreads.forEach((item) => {
      const projectPath = String(item.projectPath).trim();
      if (!groups.has(projectPath)) {
        groups.set(projectPath, { path: projectPath, name: item.projectName, threads: [] });
      }
      groups.get(projectPath).threads.push(item);
    });
    return [...groups.values()].map(({ path: projectPath, name: project, threads: projectThreads }, index) => {
      const isCollapsed = collapsedProjects.has(projectPath);
      const projectListID = `dashboard-project-${index}`;
      const runningCount = projectThreads.filter((item) => item.runState === 'running').length;
      return `
      <section class="dashboard-project-group${isCollapsed ? ' is-collapsed' : ''}" aria-label="${dashboardDOM.escapeHTML(project)} project">
        <header class="dashboard-project-heading">
          <button type="button" class="dashboard-project-toggle" data-project-toggle="${dashboardDOM.escapeHTML(projectPath)}" aria-expanded="${String(!isCollapsed)}" aria-controls="${projectListID}">
            <span class="dashboard-project-title">
              <span class="dashboard-project-chevron">${icon('chevron')}</span>
              <span class="dashboard-project-icon">${icon('project')}</span>
              <span class="dashboard-project-name">${dashboardDOM.escapeHTML(project)}</span>
              ${projectThreads.some((item) => item.workingTreeStatus === 'hasChanges') ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${icon('gitChanges')}<span>Uncommitted</span></span>` : ''}
            </span>
            <span class="dashboard-project-summary">
              ${runningCount > 0 ? `<span class="dashboard-running-spinner has-count" role="status" aria-label="${runningCount} running ${runningCount === 1 ? 'thread' : 'threads'}" title="${runningCount} running ${runningCount === 1 ? 'thread' : 'threads'}"><span aria-hidden="true">${runningCount}</span></span>` : ''}
              <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'thread' : 'threads'}</span>
            </span>
          </button>
        </header>
        <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((item) => thread(item, { isUnread: isUnread(item) })).join('')}</div>
      </section>`;
    }).join('');
  }

  return { icon, list, thread };
})();
