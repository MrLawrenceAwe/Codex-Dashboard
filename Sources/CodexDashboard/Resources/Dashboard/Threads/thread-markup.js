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
    const isForcedHalt = thread.latestLifecycleEventKind === 'forcedHalt';
    const statusMarkup = thread.runState === 'running'
      ? `<span class="dashboard-run-spinner" role="status" aria-label="Running" title="Running"></span><span class="dashboard-open-affordance" aria-hidden="true">${dashboardIcons.render('arrow')}</span>`
      : isForcedHalt
        ? `<span class="dashboard-forced-halt-status" role="status" aria-label="Interrupted because the usage limit was reached" title="This task was interrupted because the usage limit was reached">${dashboardIcons.render('forcedHalt')}<span>Interrupted</span></span>`
        : isCompleted
          ? `<span class="dashboard-completed-status" role="status" aria-label="Completed" title="Completed">${dashboardIcons.render('completed')}</span>`
          : `<span class="dashboard-open-affordance" aria-hidden="true">${dashboardIcons.render('arrow')}</span>`;
    return `<div class="dashboard-thread-row${compact ? ' is-compact' : ''}" data-dashboard-thread-row="${domUtils.escapeHTML(thread.id)}">
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
      </button>
    </div>`;
  }

  function groupThreadsByProject(threads) {
    const groups = new Map();
    threads.forEach((thread) => {
      const path = String(thread.projectPath).trim();
      if (!groups.has(path)) groups.set(path, { path, name: thread.projectName, threads: [] });
      groups.get(path).threads.push(thread);
    });
    return [...groups.values()];
  }

  function renderProjectActions(projectPath, projectThreads, indicatorsHidden) {
    if (!projectThreads.some((thread) => thread.workingTreeStatus === 'hasChanges')) return '';
    const hasIdleThread = projectThreads.some((thread) => thread.runState !== 'running');
    return `
      <button type="button" class="dashboard-project-indicators" data-project-indicators="${domUtils.escapeHTML(projectPath)}" title="${indicatorsHidden ? 'Show change indicators for this project' : 'Hide change indicators for this project'}">${dashboardIcons.render(indicatorsHidden ? 'restore' : 'mute')}<span>${indicatorsHidden ? 'Show change indicators' : 'Hide change indicators'}</span></button>
      <button type="button" class="dashboard-project-commit" data-project-commit="${domUtils.escapeHTML(projectPath)}" title="${hasIdleThread ? 'Open Codex’s Commit or push flow for this project' : 'Commit or push is available when this project has an idle task'}"${hasIdleThread ? '' : ' disabled'}>${dashboardIcons.render('gitChanges')}<span>${hasIdleThread ? 'Commit or push' : 'Task running'}</span></button>`;
  }

  function list(visibleThreads, {
    filterMode,
    collapsedProjectPaths,
    hiddenChangeIndicatorPaths,
    isUnread,
    isCompletionTickVisible,
  }) {
    if (filterMode === 'recent') {
      const renderRows = (items) => items.map((item) => thread(item, {
        compact: true,
        showProject: true,
        isUnread: isUnread(item),
        isCompletionTickVisible,
      })).join('');
      const running = visibleThreads.filter((item) => item.runState === 'running');
      if (!running.length) return renderRows(visibleThreads);
      const recent = visibleThreads.filter((item) => item.runState !== 'running');
      return `<section class="dashboard-task-section" data-dashboard-section="running" aria-label="Running tasks">
        <h2 class="dashboard-task-section-heading" data-dashboard-section-heading>Running <span>${running.length}</span></h2>
        ${renderRows(running)}
      </section>${recent.length ? `<section class="dashboard-task-section" data-dashboard-section="recent" aria-label="Recent tasks">
        <h2 class="dashboard-task-section-heading" data-dashboard-section-heading>Recents</h2>
        ${renderRows(recent)}
      </section>` : ''}`;
    }
    if (filterMode === 'changedProjects') {
      const projects = groupThreadsByProject(visibleThreads);
      const projectCard = ({ path: projectPath, name: projectName, threads: projectThreads }) => {
        return `
        <article class="dashboard-git-project" data-dashboard-git-project="${domUtils.escapeHTML(projectPath)}">
          <div class="dashboard-git-project-copy">
            <span class="dashboard-project-icon">${dashboardIcons.render('project')}</span>
            <span class="dashboard-project-copy">
              <span class="dashboard-project-name">${domUtils.escapeHTML(projectName)}</span>
              <span class="dashboard-project-path">${domUtils.escapeHTML(projectPath)}</span>
            </span>
            <span class="dashboard-git-changes">${dashboardIcons.render('gitChanges')}<span>Changed</span></span>
          </div>
          <span class="dashboard-project-summary">
            ${renderProjectActions(projectPath, projectThreads, hiddenChangeIndicatorPaths.has(projectPath))}
          </span>
        </article>`;
      };
      const projectsWithVisibleIndicators = [];
      const projectsWithHiddenIndicators = [];
      projects.forEach((project) => {
        (hiddenChangeIndicatorPaths.has(project.path) ? projectsWithHiddenIndicators : projectsWithVisibleIndicators).push(project);
      });
      return `
        ${projectsWithVisibleIndicators.map(projectCard).join('')}
        ${projectsWithHiddenIndicators.length ? `
          <details class="dashboard-hidden-indicators" data-dashboard-hidden-indicators>
            <summary><span class="dashboard-hidden-indicators-label">Indicators hidden</span><span class="dashboard-hidden-indicators-count">${projectsWithHiddenIndicators.length}</span></summary>
            <div class="dashboard-hidden-indicators-list">${projectsWithHiddenIndicators.map(projectCard).join('')}</div>
          </details>` : ''}`;
    }
    return groupThreadsByProject(visibleThreads).map(({ path: projectPath, name: project, threads: projectThreads }, index) => {
      const isCollapsed = collapsedProjectPaths.has(projectPath);
      const projectListID = `dashboard-project-${index}`;
      const hasChanges = projectThreads.some((item) => item.workingTreeStatus === 'hasChanges');
      const indicatorsHidden = hiddenChangeIndicatorPaths.has(projectPath);
      return `
      <section class="dashboard-project-group${isCollapsed ? ' is-collapsed' : ''}" data-dashboard-project-group="${domUtils.escapeHTML(projectPath)}" aria-label="${domUtils.escapeHTML(project)} project">
        <header class="dashboard-project-heading">
          <button type="button" class="dashboard-project-toggle" data-project-toggle="${domUtils.escapeHTML(projectPath)}" aria-expanded="${String(!isCollapsed)}" aria-controls="${projectListID}">
            <span class="dashboard-project-title">
              <span class="dashboard-project-chevron">${dashboardIcons.render('chevron')}</span>
              <span class="dashboard-project-icon">${dashboardIcons.render('project')}</span>
              <span class="dashboard-project-copy">
                <span class="dashboard-project-name">${domUtils.escapeHTML(project)}</span>
                <span class="dashboard-project-path">${domUtils.escapeHTML(projectPath)}</span>
              </span>
              ${hasChanges && !indicatorsHidden ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${dashboardIcons.render('gitChanges')}<span>Changed</span></span>` : ''}
              ${hasChanges && indicatorsHidden ? '<span class="dashboard-project-indicators-hidden" title="Change indicators are hidden for this project">Indicators hidden</span>' : ''}
            </span>
          </button>
          <span class="dashboard-project-summary">
            <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'task' : 'tasks'}</span>
            ${renderProjectActions(projectPath, projectThreads, indicatorsHidden)}
          </span>
        </header>
        <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((item) => thread(item, { isUnread: isUnread(item), isCompletionTickVisible })).join('')}</div>
      </section>`;
    }).join('');
  }

  return { list };
})();
