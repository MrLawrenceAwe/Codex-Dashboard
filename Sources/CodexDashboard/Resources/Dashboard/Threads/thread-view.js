const threadDashboardView = (() => {
  const renderedMarkup = new WeakMap();

  function updateMarkup(element, markup) {
    if (renderedMarkup.get(element) === markup) return;
    element.innerHTML = markup;
    renderedMarkup.set(element, markup);
  }

  function updateSidebarStatus({ unreadCount, runningThreads, dirtyProjectPaths }) {
    const unreadBadge = document.querySelector('[data-navigation-count]');
    if (unreadBadge) {
      unreadBadge.textContent = String(unreadCount);
      unreadBadge.hidden = unreadCount === 0;
      unreadBadge.setAttribute(
        'aria-label',
        `${unreadCount} unread ${unreadCount === 1 ? 'thread' : 'threads'}`,
      );
    }
    const spinner = document.querySelector('[data-navigation-running]');
    if (spinner) {
      const runningCount = runningThreads.length;
      const runningLabel = `${runningCount} running ${runningCount === 1 ? 'thread' : 'threads'}`;
      spinner.hidden = runningCount === 0;
      spinner.setAttribute('aria-label', runningLabel);
      spinner.setAttribute('title', runningLabel);
      const spinnerCount = spinner.querySelector('[data-navigation-running-count]');
      if (spinnerCount) spinnerCount.textContent = String(runningCount);
    }
    const changes = document.querySelector('[data-navigation-changes]');
    if (changes) {
      const changedProjectCount = dirtyProjectPaths.size;
      const changedProjectNames = [...dirtyProjectPaths]
        .map((path) => path.split('/').filter(Boolean).at(-1) || path)
        .slice(0, 3);
      const changedProjectLabel = `${changedProjectCount} ${changedProjectCount === 1 ? 'project has' : 'projects have'} uncommitted changes${changedProjectNames.length ? `: ${changedProjectNames.join(', ')}` : ''}`;
      changes.hidden = changedProjectCount === 0;
      changes.setAttribute('aria-label', changedProjectLabel);
      changes.setAttribute('title', changedProjectLabel);
    }
  }

  function updateHeaderSummary({ unreadCount, runningThreads, dirtyProjectPaths }) {
    const page = document.getElementById(dashboardElements.elementIDs.page);
    if (!page) return;
    const values = {
      running: runningThreads.length,
      unread: unreadCount,
      changed: dirtyProjectPaths.size,
    };
    page.querySelectorAll('[data-summary-count]').forEach((count) => {
      count.textContent = String(values[count.dataset.summaryCount] ?? 0);
    });
    const summary = page.querySelector('[data-dashboard-summary]');
    if (summary) {
      summary.setAttribute(
        'aria-label',
        `${values.running} running, ${values.unread} unread, ${values.changed} changed ${values.changed === 1 ? 'project' : 'projects'}`,
      );
    }
  }

  function render({
    threads,
    filterMode,
    searchTerm,
    visibleThreadLimit,
    collapsedProjects,
    ignoredProjectPaths,
    commitOrPushError,
    isThreadUnread,
    state,
  }) {
    updateSidebarStatus(state);
    updateHeaderSummary(state);
    const page = document.getElementById(dashboardElements.elementIDs.page);
    if (!page) return false;
    const notice = page.querySelector('[data-dashboard-notice]');
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
      running: state.runningThreads.length,
      unread: state.unreadCount,
      changedProjects: state.changedProjectPaths.size,
    };
    page.querySelectorAll('[data-filter-count]').forEach((count) => {
      count.textContent = String(filterCounts[count.dataset.filterCount] ?? 0);
    });
    const visibleThreads = threadDashboardState.filter({
      threads,
      allChangedProjectPaths: state.allChangedProjectPaths,
      filterMode,
      searchTerm,
      isThreadUnread,
    });
    const displayedThreads = visibleThreads.slice(0, visibleThreadLimit);
    const loadMore = page.querySelector('[data-load-more]');
    if (loadMore) loadMore.hidden = displayedThreads.length >= visibleThreads.length;
    const list = page.querySelector('[data-thread-list]');
    if (!visibleThreads.length) {
      const emptyMessage = filterMode === 'unread' && !searchTerm.trim()
        ? 'You’re all caught up'
        : 'No threads found';
      updateMarkup(list, `<div class="dashboard-empty"><strong>${emptyMessage}</strong></div>`);
      return true;
    }
    updateMarkup(
      list,
      threadMarkup.list(displayedThreads, {
        filterMode,
        collapsedProjects,
        ignoredProjectPaths,
        isUnread: isThreadUnread,
      }),
    );
    return true;
  }

  return { render, updateSidebarStatus };
})();
