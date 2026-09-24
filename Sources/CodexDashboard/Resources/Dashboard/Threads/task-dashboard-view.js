const taskDashboardView = (() => {
  const renderedMarkup = new WeakMap();

  function childKey(element) {
    if (!(element instanceof Element)) return '';
    if (element.matches('[data-dashboard-thread-row]')) {
      return `thread:${element.dataset.dashboardThreadRow}`;
    }
    if (element.matches('[data-dashboard-project-group]')) {
      return `project:${element.dataset.dashboardProjectGroup}`;
    }
    if (element.matches('[data-dashboard-git-project]')) {
      return `git:${element.dataset.dashboardGitProject}`;
    }
    if (element.matches('[data-dashboard-section]')) {
      return `section:${element.dataset.dashboardSection}`;
    }
    if (element.matches('[data-dashboard-section-heading]')) return 'section-heading';
    if (element.matches('[data-dashboard-hidden-indicators]')) return 'hidden-indicators';
    if (element.matches('[data-dashboard-empty]')) return 'empty';
    return '';
  }

  function updateMarkup(element, markup) {
    if (renderedMarkup.get(element) === markup) return;
    const template = document.createElement('template');
    template.innerHTML = markup;
    const nextChildren = [...template.content.children];
    const currentChildren = [...element.children];
    const currentByKey = new Map(currentChildren.map((child) => [childKey(child), child]));
    const canPatch = nextChildren.every((child) => childKey(child))
      && currentChildren.every((child) => childKey(child))
      && currentByKey.size === currentChildren.length;
    if (!canPatch) {
      element.replaceChildren(template.content);
    } else {
      const retained = new Set();
      nextChildren.forEach((nextChild) => {
        const key = childKey(nextChild);
        const currentChild = currentByKey.get(key);
        let child = currentChild?.outerHTML === nextChild.outerHTML ? currentChild : nextChild;
        if (currentChild && child === nextChild && key.startsWith('section:')) {
          updateMarkup(currentChild, nextChild.innerHTML);
          child = currentChild;
        }
        retained.add(child);
        element.append(child);
      });
      currentChildren.forEach((child) => {
        if (!retained.has(child) && child.isConnected) child.remove();
      });
    }
    renderedMarkup.set(element, markup);
  }

  function updateSidebarStatus({ unreadCount, runningCount, indicatedChangedProjectPaths }) {
    const unreadBadge = document.querySelector('[data-navigation-count]');
    if (unreadBadge) {
      unreadBadge.textContent = String(unreadCount);
      unreadBadge.hidden = unreadCount === 0;
      unreadBadge.setAttribute(
        'aria-label',
        `${unreadCount} unread ${unreadCount === 1 ? 'task' : 'tasks'}`,
      );
    }
    const spinner = document.querySelector('[data-navigation-running]');
    if (spinner) {
      const runningLabel = `${runningCount} running ${runningCount === 1 ? 'task' : 'tasks'}`;
      spinner.hidden = runningCount === 0;
      spinner.setAttribute('aria-label', runningLabel);
      spinner.setAttribute('title', runningLabel);
      const spinnerCount = spinner.querySelector('[data-navigation-running-count]');
      if (spinnerCount) spinnerCount.textContent = String(runningCount);
    }
    const changes = document.querySelector('[data-navigation-changes]');
    if (changes) {
      const changedProjectCount = indicatedChangedProjectPaths.size;
      const changedProjectNames = [...indicatedChangedProjectPaths]
        .map((path) => path.split('/').filter(Boolean).at(-1) || path)
        .slice(0, 3);
      const changedProjectLabel = `${changedProjectCount} ${changedProjectCount === 1 ? 'project has' : 'projects have'} uncommitted changes${changedProjectNames.length ? `: ${changedProjectNames.join(', ')}` : ''}`;
      changes.hidden = changedProjectCount === 0;
      changes.setAttribute('aria-label', changedProjectLabel);
      changes.setAttribute('title', changedProjectLabel);
    }
  }

  function render({
    threads,
    filterMode,
    visibleThreadLimit,
    collapsedProjectPaths,
    hiddenChangeIndicatorPaths,
    commitOrPushError,
    isThreadUnread,
    isCompletionTickVisible,
    state,
  }) {
    updateSidebarStatus(state);
    const page = document.getElementById(dashboardElements.elementIDs.taskPage);
    if (!page) return false;
    const notice = page.querySelector('[data-commit-notice]');
    if (notice) {
      notice.textContent = commitOrPushError;
      notice.hidden = !commitOrPushError;
    }
    page.querySelectorAll('[data-filter]').forEach((button) => {
      const isActive = button.dataset.filter === filterMode;
      button.classList.toggle('is-active', isActive);
      button.setAttribute('aria-pressed', String(isActive));
    });
    const filterCounts = {
      unread: state.unreadCount,
      changedProjects: state.indicatedChangedProjectPaths.size,
    };
    page.querySelectorAll('[data-filter-count]').forEach((count) => {
      count.textContent = String(filterCounts[count.dataset.filterCount] ?? 0);
    });
    const visibleThreads = taskDashboardState.filter({
      threads,
      allChangedProjectPaths: state.allChangedProjectPaths,
      filterMode,
      isThreadUnread,
    });
    const changedProjectPaths = filterMode === 'changedProjects'
      ? [...new Set(visibleThreads.map((thread) => String(thread.projectPath).trim()))]
      : null;
    const displayedChangedProjectPaths = changedProjectPaths?.slice(0, visibleThreadLimit);
    const recentThreads = filterMode === 'recent'
      ? visibleThreads.filter((thread) => thread.runState !== 'running')
      : null;
    const displayedThreads = changedProjectPaths
      ? visibleThreads.filter((thread) => displayedChangedProjectPaths
        .includes(String(thread.projectPath).trim()))
      : filterMode === 'recent'
        ? [...visibleThreads.filter((thread) => thread.runState === 'running'),
          ...recentThreads.slice(0, visibleThreadLimit)]
        : visibleThreads.slice(0, visibleThreadLimit);
    const loadMore = page.querySelector('[data-load-more]');
    if (loadMore) loadMore.hidden = changedProjectPaths
      ? visibleThreadLimit >= changedProjectPaths.length
      : filterMode === 'recent'
        ? visibleThreadLimit >= recentThreads.length
        : displayedThreads.length >= visibleThreads.length;
    const list = page.querySelector('[data-thread-list]');
    list.classList.toggle('is-compact', filterMode === 'recent');
    if (!visibleThreads.length) {
      const emptyMessage = filterMode === 'unread'
        ? 'You’re all caught up'
        : 'No tasks found';
      updateMarkup(list, `<div class="dashboard-empty" data-dashboard-empty><strong>${emptyMessage}</strong></div>`);
      return true;
    }
    updateMarkup(
      list,
      threadMarkup.list(displayedThreads, {
        filterMode,
        collapsedProjectPaths,
        hiddenChangeIndicatorPaths,
        isUnread: isThreadUnread,
        isCompletionTickVisible,
      }),
    );
    return true;
  }

  return { render, updateSidebarStatus };
})();
