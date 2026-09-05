const threadMarkup = (() => {
  function formatRelativeTime(timestamp) {
    const seconds = Math.max(0, Math.round(Date.now() / 1000 - Number(timestamp || 0)));
    if (seconds < 60) return 'just now';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    return `${Math.floor(hours / 24)}d ago`;
  }

  function thread(thread, {
    showProject = false,
    isUnread = false,
    isCompletionTickVisible = () => false,
    compact = false,
  } = {}) {
    const openLabel = `${isUnread ? 'Unread. ' : ''}Open task: ${thread.title}`;
    const isCompleted = isCompletionTickVisible(thread);
    const statusMarkup = thread.runState === 'running'
      ? `<span class="dashboard-run-spinner" role="status" aria-label="Running" title="Running"></span><span class="dashboard-open-affordance" aria-hidden="true">${dashboardIcons.render('arrow')}</span>`
      : isCompleted
        ? `<span class="dashboard-completed-status" role="status" aria-label="Completed" title="Completed">${dashboardIcons.render('completed')}</span>`
        : `<span class="dashboard-open-affordance" aria-hidden="true">${dashboardIcons.render('arrow')}</span>`;
    return `
      <button type="button" class="dashboard-thread${compact ? ' is-compact' : ''}" data-run-state="${domUtils.escapeHTML(thread.runState)}" data-unread="${String(isUnread)}" data-thread-id="${domUtils.escapeHTML(thread.id)}" data-open-thread="${domUtils.escapeHTML(thread.id)}" aria-label="${domUtils.escapeHTML(openLabel)}">
        <span class="dashboard-thread-copy">
          <span class="dashboard-thread-title-row">
            ${isUnread ? '<span class="dashboard-unread-dot" role="status" aria-label="Unread response" title="Unread response"></span>' : ''}
            <span class="dashboard-thread-heading" role="heading" aria-level="2">${domUtils.escapeHTML(thread.title)}</span>
            ${thread.isPinned ? `<span class="dashboard-pin" title="Pinned">${dashboardIcons.render('pin')}</span>` : ''}
          </span>
          ${compact
            ? `<span class="dashboard-meta">
                ${showProject ? `<span>${domUtils.escapeHTML(thread.projectName)}</span>` : ''}
                <span>${formatRelativeTime(Number(thread.recencyEpochMillis || 0) / 1000)}</span>
              </span>`
            : `<span class="dashboard-thread-details">
                <span class="dashboard-thread-preview">${domUtils.escapeHTML(thread.preview || 'No preview available')}</span>
                <span class="dashboard-meta">
                  <span>${formatRelativeTime(Number(thread.recencyEpochMillis || 0) / 1000)}</span>
                  ${thread.model ? `<span>${domUtils.escapeHTML(thread.model)}</span>` : ''}
                </span>
              </span>`}
        </span>
        <span class="dashboard-thread-actions">
          ${statusMarkup}
        </span>
      </button>`;
  }

  function list(visibleThreads, {
    filterMode,
    collapsedProjects,
    ignoredProjectPaths,
    isUnread,
    isCompletionTickVisible,
  }) {
    if (filterMode === 'today') {
      return visibleThreads.map((item) => thread(item, {
        compact: true,
        showProject: true,
        isUnread: isUnread(item),
        isCompletionTickVisible,
      })).join('');
    }
    if (filterMode === 'changedProjects') {
      const projects = new Map();
      visibleThreads.forEach((item) => {
        const projectPath = String(item.projectPath).trim();
        if (!projects.has(projectPath)) projects.set(projectPath, []);
        projects.get(projectPath).push(item);
      });
      const projectCard = ([projectPath, projectThreads]) => {
        const project = projectThreads[0];
        const hasIdleThread = projectThreads.some((thread) => thread.runState !== 'running');
        return `
        <article class="dashboard-git-project">
          <div class="dashboard-git-project-copy">
            <span class="dashboard-project-icon">${dashboardIcons.render('project')}</span>
            <span class="dashboard-project-copy">
              <span class="dashboard-project-name">${domUtils.escapeHTML(project.projectName)}</span>
              <span class="dashboard-project-path">${domUtils.escapeHTML(projectPath)}</span>
            </span>
            <span class="dashboard-git-changes">${dashboardIcons.render('gitChanges')}<span>Changed</span></span>
          </div>
          <span class="dashboard-project-summary">
            <button type="button" class="dashboard-project-ignore" data-project-ignore="${domUtils.escapeHTML(projectPath)}" title="${ignoredProjectPaths.has(projectPath) ? 'Unmute change notifications for this project' : 'Mute change notifications for this project'}">${dashboardIcons.render(ignoredProjectPaths.has(projectPath) ? 'restore' : 'ignore')}<span>${ignoredProjectPaths.has(projectPath) ? 'Unmute changes' : 'Mute changes'}</span></button>
            ${ignoredProjectPaths.has(projectPath) ? '' : `<button type="button" class="dashboard-project-commit" data-project-commit="${domUtils.escapeHTML(projectPath)}" title="${hasIdleThread ? 'Open Codex’s Commit or push flow for this project' : 'Commit or push is available when this project has an idle task'}"${hasIdleThread ? '' : ' disabled'}>${dashboardIcons.render('gitChanges')}<span>${hasIdleThread ? 'Commit or push' : 'Task running'}</span></button>`}
          </span>
        </article>`;
      };
      const activeProjects = [];
      const ignoredProjects = [];
      projects.forEach((project, projectPath) => {
        (ignoredProjectPaths.has(projectPath) ? ignoredProjects : activeProjects).push([projectPath, project]);
      });
      return `
        ${activeProjects.map(projectCard).join('')}
        ${ignoredProjects.length ? `
          <details class="dashboard-ignored-projects">
            <summary><span class="dashboard-ignored-project-label">Muted</span><span class="dashboard-ignored-project-count">${ignoredProjects.length}</span></summary>
            <div class="dashboard-ignored-project-list">${ignoredProjects.map(projectCard).join('')}</div>
          </details>` : ''}`;
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
      <section class="dashboard-project-group${isCollapsed ? ' is-collapsed' : ''}" aria-label="${domUtils.escapeHTML(project)} project">
        <header class="dashboard-project-heading">
          <button type="button" class="dashboard-project-toggle" data-project-toggle="${domUtils.escapeHTML(projectPath)}" aria-expanded="${String(!isCollapsed)}" aria-controls="${projectListID}">
            <span class="dashboard-project-title">
              <span class="dashboard-project-chevron">${dashboardIcons.render('chevron')}</span>
              <span class="dashboard-project-icon">${dashboardIcons.render('project')}</span>
              <span class="dashboard-project-copy">
                <span class="dashboard-project-name">${domUtils.escapeHTML(project)}</span>
                <span class="dashboard-project-path">${domUtils.escapeHTML(projectPath)}</span>
              </span>
              ${hasChanges && !isIgnored ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${dashboardIcons.render('gitChanges')}<span>Changed</span></span>` : ''}
              ${hasChanges && isIgnored ? '<span class="dashboard-project-ignored" title="Change notifications are muted for this project">Muted</span>' : ''}
            </span>
          </button>
          <span class="dashboard-project-summary">
            <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'task' : 'tasks'}</span>
            ${hasChanges ? `<button type="button" class="dashboard-project-ignore" data-project-ignore="${domUtils.escapeHTML(projectPath)}" title="${isIgnored ? 'Unmute change notifications for this project' : 'Mute change notifications for this project'}">${dashboardIcons.render(isIgnored ? 'restore' : 'ignore')}<span>${isIgnored ? 'Unmute changes' : 'Mute changes'}</span></button>` : ''}
            ${hasChanges && !isIgnored ? `<button type="button" class="dashboard-project-commit" data-project-commit="${domUtils.escapeHTML(projectPath)}" title="Open Codex’s Commit or push flow for this project">${dashboardIcons.render('gitChanges')}<span>Commit or push</span></button>` : ''}
          </span>
        </header>
        <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((item) => thread(item, { isUnread: isUnread(item), isCompletionTickVisible })).join('')}</div>
      </section>`;
    }).join('');
  }

  return { list, thread };
})();
