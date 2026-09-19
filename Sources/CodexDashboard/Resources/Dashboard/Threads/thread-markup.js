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
    isChatInTodos = () => false,
    compact = false,
  } = {}) {
    const openLabel = `${isUnread ? 'Unread. ' : ''}Open task: ${thread.title}`;
    const isCompleted = isCompletionTickVisible(thread);
    const isForcedHalt = thread.latestLifecycleEventKind === 'forcedHalt';
    const isAddedToTodos = isChatInTodos(thread.id);
    const statusMarkup = thread.runState === 'running'
      ? `<span class="dashboard-run-spinner" role="status" aria-label="Running" title="Running"></span><span class="dashboard-open-affordance" aria-hidden="true">${dashboardIcons.render('arrow')}</span>`
      : isForcedHalt
        ? `<span class="dashboard-forced-halt-status" role="status" aria-label="Interrupted because the usage limit was reached" title="This task was interrupted because the usage limit was reached">${dashboardIcons.render('forcedHalt')}<span>Interrupted</span></span>`
        : isCompleted
          ? `<span class="dashboard-completed-status" role="status" aria-label="Completed" title="Completed">${dashboardIcons.render('completed')}</span>`
          : `<span class="dashboard-open-affordance" aria-hidden="true">${dashboardIcons.render('arrow')}</span>`;
    return `<div class="dashboard-thread-row${compact ? ' is-compact' : ''}" data-dashboard-thread-row="${domUtils.escapeHTML(thread.id)}">
      <button type="button" class="dashboard-add-todo${isAddedToTodos ? ' is-added' : ''}" data-add-chat-to-todos="${domUtils.escapeHTML(thread.id)}" aria-label="${isAddedToTodos ? `${domUtils.escapeHTML(thread.title)} is in to-dos` : `Add ${domUtils.escapeHTML(thread.title)} to to-dos`}" title="${isAddedToTodos ? 'Already in to-dos' : 'Add chat to to-dos'}"${isAddedToTodos ? ' disabled' : ''}><span aria-hidden="true">${isAddedToTodos ? '✓' : '+'}</span><span>${isAddedToTodos ? 'Added' : 'To-do'}</span></button>
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

  function renderProjectActions(projectPath, projectThreads, isMuted) {
    if (!projectThreads.some((thread) => thread.workingTreeStatus === 'hasChanges')) return '';
    const hasIdleThread = projectThreads.some((thread) => thread.runState !== 'running');
    return `
      <button type="button" class="dashboard-project-mute" data-project-mute="${domUtils.escapeHTML(projectPath)}" title="${isMuted ? 'Unmute change notifications for this project' : 'Mute change notifications for this project'}">${dashboardIcons.render(isMuted ? 'restore' : 'mute')}<span>${isMuted ? 'Unmute change alerts' : 'Mute change alerts'}</span></button>
      ${isMuted ? '' : `<button type="button" class="dashboard-project-commit" data-project-commit="${domUtils.escapeHTML(projectPath)}" title="${hasIdleThread ? 'Open Codex’s Commit or push flow for this project' : 'Commit or push is available when this project has an idle task'}"${hasIdleThread ? '' : ' disabled'}>${dashboardIcons.render('gitChanges')}<span>${hasIdleThread ? 'Commit or push' : 'Task running'}</span></button>`}`;
  }

  function renderProjectTodoPicker(projectThreads, isChatInTodos) {
    return `<details class="dashboard-project-chat-picker">
      <summary aria-label="Choose a chat from this project to add to to-dos" title="Add a project chat to to-dos"><span aria-hidden="true">+</span><span>To-do</span></summary>
      <span class="dashboard-project-chat-menu" role="menu" aria-label="Project chats">
        ${projectThreads.map((item) => {
          const isAdded = isChatInTodos(item.id);
          return `<button type="button" role="menuitem" data-add-chat-to-todos="${domUtils.escapeHTML(item.id)}"${isAdded ? ' disabled' : ''} title="${isAdded ? 'Already in to-dos' : 'Add chat to to-dos'}"><span class="dashboard-project-chat-title">${domUtils.escapeHTML(item.title)}</span><span class="dashboard-project-chat-state">${isAdded ? 'Added' : 'Add'}</span></button>`;
        }).join('')}
      </span>
    </details>`;
  }

  function list(visibleThreads, {
    allThreads = visibleThreads,
    filterMode,
    collapsedProjectPaths,
    mutedProjectPaths,
    isUnread,
    isCompletionTickVisible,
    isChatInTodos = () => false,
  }) {
    const allThreadsByProject = new Map(
      groupThreadsByProject(allThreads).map((group) => [group.path, group.threads]),
    );
    if (filterMode === 'recent') {
      return visibleThreads.map((item) => thread(item, {
        compact: true,
        showProject: true,
        isUnread: isUnread(item),
        isCompletionTickVisible,
        isChatInTodos,
      })).join('');
    }
    if (filterMode === 'changedProjects') {
      const projects = groupThreadsByProject(visibleThreads);
      const projectCard = ({ path: projectPath, name: projectName, threads: projectThreads }) => {
        const selectableProjectThreads = allThreadsByProject.get(projectPath) || [];
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
            ${renderProjectTodoPicker(selectableProjectThreads, isChatInTodos)}
            ${renderProjectActions(projectPath, projectThreads, mutedProjectPaths.has(projectPath))}
          </span>
        </article>`;
      };
      const activeProjects = [];
      const mutedProjects = [];
      projects.forEach((project) => {
        (mutedProjectPaths.has(project.path) ? mutedProjects : activeProjects).push(project);
      });
      return `
        ${activeProjects.map(projectCard).join('')}
        ${mutedProjects.length ? `
          <details class="dashboard-muted-projects" data-dashboard-muted-projects>
            <summary><span class="dashboard-muted-project-label">Muted</span><span class="dashboard-muted-project-count">${mutedProjects.length}</span></summary>
            <div class="dashboard-muted-project-list">${mutedProjects.map(projectCard).join('')}</div>
          </details>` : ''}`;
    }
    return groupThreadsByProject(visibleThreads).map(({ path: projectPath, name: project, threads: projectThreads }, index) => {
      const selectableProjectThreads = allThreadsByProject.get(projectPath) || [];
      const isCollapsed = collapsedProjectPaths.has(projectPath);
      const projectListID = `dashboard-project-${index}`;
      const hasChanges = projectThreads.some((item) => item.workingTreeStatus === 'hasChanges');
      const isMuted = mutedProjectPaths.has(projectPath);
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
              ${hasChanges && !isMuted ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${dashboardIcons.render('gitChanges')}<span>Changed</span></span>` : ''}
              ${hasChanges && isMuted ? '<span class="dashboard-project-muted" title="Change notifications are muted for this project">Muted</span>' : ''}
            </span>
          </button>
          <span class="dashboard-project-summary">
            <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'task' : 'tasks'}</span>
            ${renderProjectTodoPicker(selectableProjectThreads, isChatInTodos)}
            ${renderProjectActions(projectPath, projectThreads, isMuted)}
          </span>
        </header>
        <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((item) => thread(item, { isUnread: isUnread(item), isCompletionTickVisible, isChatInTodos })).join('')}</div>
      </section>`;
    }).join('');
  }

  return { list };
})();
