const taskDashboardView = (() => {
  const renderedMarkup = new WeakMap();

  function updateMarkup(element, markup) {
    if (renderedMarkup.get(element) === markup) return;
    element.innerHTML = markup;
    renderedMarkup.set(element, markup);
  }

  function updateSidebarStatus({ unreadCount, runningCount, unmutedChangedProjectPaths }) {
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
      const changedProjectCount = unmutedChangedProjectPaths.size;
      const changedProjectNames = [...unmutedChangedProjectPaths]
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
    collapsedProjects,
    mutedProjectPaths,
    commitOrPushError,
    isThreadUnread,
    isCompletionTickVisible,
    state,
  }) {
    updateSidebarStatus(state);
    const page = document.getElementById(dashboardElements.elementIDs.page);
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
      running: state.runningCount,
      unread: state.unreadCount,
      changedProjects: state.unmutedChangedProjectPaths.size,
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
    const displayedThreads = changedProjectPaths
      ? visibleThreads.filter((thread) => displayedChangedProjectPaths
        .includes(String(thread.projectPath).trim()))
      : visibleThreads.slice(0, visibleThreadLimit);
    const loadMore = page.querySelector('[data-load-more]');
    if (loadMore) loadMore.hidden = changedProjectPaths
      ? visibleThreadLimit >= changedProjectPaths.length
      : displayedThreads.length >= visibleThreads.length;
    const list = page.querySelector('[data-thread-list]');
    list.classList.toggle('is-compact', filterMode === 'recent');
    if (!visibleThreads.length) {
      const emptyMessage = filterMode === 'unread'
        ? 'You’re all caught up'
        : 'No tasks found';
      updateMarkup(list, `<div class="dashboard-empty"><strong>${emptyMessage}</strong></div>`);
      return true;
    }
    updateMarkup(
      list,
      threadMarkup.list(displayedThreads, {
        filterMode,
        collapsedProjects,
        mutedProjectPaths,
        isUnread: isThreadUnread,
        isCompletionTickVisible,
      }),
    );
    return true;
  }

  return { render, updateSidebarStatus };
})();
