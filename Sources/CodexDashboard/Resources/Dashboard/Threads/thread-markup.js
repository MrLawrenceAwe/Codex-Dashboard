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
      ignore: '<path d="M4 4l16 16M10.6 10.7a2 2 0 0 0 2.7 2.7M9.9 4.2A10.6 10.6 0 0 1 21 12a12.7 12.7 0 0 1-3.1 4.2M6.2 6.2A12.8 12.8 0 0 0 3 12a10.7 10.7 0 0 0 6.1 6.9"/>',
      restore: '<path d="M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5"/>',
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

  function thread(thread, { showProject = false, isUnread = false, compact = false } = {}) {
    const openLabel = `${isUnread ? 'Unread. ' : ''}Open thread: ${thread.title}`;
    return `
      <button type="button" class="dashboard-thread${compact ? ' is-compact' : ''}" data-run-state="${dashboardDOM.escapeHTML(thread.runState)}" data-unread="${String(isUnread)}" data-thread-id="${dashboardDOM.escapeHTML(thread.id)}" data-open-thread="${dashboardDOM.escapeHTML(thread.id)}" aria-label="${dashboardDOM.escapeHTML(openLabel)}">
        <span class="dashboard-thread-copy">
          <span class="dashboard-thread-title-row">
            ${isUnread ? '<span class="dashboard-unread-dot" role="status" aria-label="Unread response" title="Unread response"></span>' : ''}
            <span class="dashboard-thread-heading" role="heading" aria-level="2">${dashboardDOM.escapeHTML(thread.title)}</span>
            ${thread.isPinned ? `<span class="dashboard-pin" title="Pinned">${icon('pin')}</span>` : ''}
          </span>
          ${compact ? '' : `<span class="dashboard-thread-preview">${dashboardDOM.escapeHTML(thread.preview || 'No preview available')}</span>`}
          <span class="dashboard-meta">
            ${showProject ? `<span>${dashboardDOM.escapeHTML(thread.projectName)}</span>` : ''}
            <span>${formatRelativeTime(thread.recencyTimestamp)}</span>
            ${!compact && thread.model ? `<span>${dashboardDOM.escapeHTML(thread.model)}</span>` : ''}
          </span>
        </span>
        <span class="dashboard-thread-actions">
          ${thread.runState === 'running' ? '<span class="dashboard-run-spinner" role="status" aria-label="Running" title="Running"></span>' : ''}
          <span class="dashboard-open-affordance" aria-hidden="true">${icon('arrow')}</span>
        </span>
      </button>`;
  }

  function list(visibleThreads, {
    viewMode,
    filterMode,
    collapsedProjects,
    ignoredProjectPaths,
    isUnread,
  }) {
    if (filterMode === 'changedProjects') {
      const projects = new Map();
      visibleThreads.forEach((item) => {
        const projectPath = String(item.projectPath).trim();
        if (!projects.has(projectPath)) projects.set(projectPath, item);
      });
      return [...projects.entries()].map(([projectPath, project]) => `
        <article class="dashboard-git-project">
          <div class="dashboard-git-project-copy">
            <span class="dashboard-project-icon">${icon('project')}</span>
            <span class="dashboard-project-copy">
              <span class="dashboard-project-name">${dashboardDOM.escapeHTML(project.projectName)}</span>
              <span class="dashboard-project-path">${dashboardDOM.escapeHTML(projectPath)}</span>
            </span>
            <span class="dashboard-git-changes">${icon('gitChanges')}<span>Changed</span></span>
          </div>
          <button type="button" class="dashboard-project-commit" data-project-commit="${dashboardDOM.escapeHTML(projectPath)}" title="Open Codex’s Commit or push flow for this project">${icon('gitChanges')}<span>Commit or push</span></button>
        </article>`).join('');
    }
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
      const hasChanges = projectThreads.some((item) => item.workingTreeStatus === 'hasChanges');
      const isIgnored = ignoredProjectPaths.has(projectPath);
      return `
      <section class="dashboard-project-group${isCollapsed ? ' is-collapsed' : ''}" aria-label="${dashboardDOM.escapeHTML(project)} project">
        <header class="dashboard-project-heading">
          <button type="button" class="dashboard-project-toggle" data-project-toggle="${dashboardDOM.escapeHTML(projectPath)}" aria-expanded="${String(!isCollapsed)}" aria-controls="${projectListID}">
            <span class="dashboard-project-title">
              <span class="dashboard-project-chevron">${icon('chevron')}</span>
              <span class="dashboard-project-icon">${icon('project')}</span>
              <span class="dashboard-project-copy">
                <span class="dashboard-project-name">${dashboardDOM.escapeHTML(project)}</span>
                <span class="dashboard-project-path">${dashboardDOM.escapeHTML(projectPath)}</span>
              </span>
              ${hasChanges && !isIgnored ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${icon('gitChanges')}<span>Changed</span></span>` : ''}
              ${hasChanges && isIgnored ? '<span class="dashboard-project-ignored" title="Change notifications are ignored for this project">Ignored</span>' : ''}
            </span>
          </button>
          <span class="dashboard-project-summary">
            <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'thread' : 'threads'}</span>
            ${hasChanges ? `<button type="button" class="dashboard-project-ignore" data-project-ignore="${dashboardDOM.escapeHTML(projectPath)}" title="${isIgnored ? 'Restore change notifications for this project' : 'Ignore change notifications for this project'}">${icon(isIgnored ? 'restore' : 'ignore')}<span>${isIgnored ? 'Restore' : 'Ignore'}</span></button>` : ''}
            ${hasChanges && !isIgnored ? `<button type="button" class="dashboard-project-commit" data-project-commit="${dashboardDOM.escapeHTML(projectPath)}" title="Open Codex’s Commit or push flow for this project">${icon('gitChanges')}<span>Commit or push</span></button>` : ''}
          </span>
        </header>
        <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((item) => thread(item, { isUnread: isUnread(item) })).join('')}</div>
      </section>`;
    }).join('');
  }

  return { icon, list, thread };
})();
