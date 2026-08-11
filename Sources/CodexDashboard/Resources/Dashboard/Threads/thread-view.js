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
      const changedProjectLabel = `${changedProjectCount} ${changedProjectCount === 1 ? 'project has' : 'projects have'} uncommitted changes`;
      changes.hidden = changedProjectCount === 0;
      changes.setAttribute('aria-label', changedProjectLabel);
      changes.setAttribute('title', changedProjectLabel);
    }
  }

  function render({
    threads,
    filterMode,
    searchTerm,
    visibleThreadLimit,
    viewMode,
    collapsedProjects,
    handoffError,
    isThreadUnread,
    state,
  }) {
    updateSidebarStatus(state);
    const page = document.getElementById(dashboardDOM.elementIDs.page);
    if (!page) return false;
    const notice = page.querySelector('[data-dashboard-notice]');
    if (notice) {
      notice.textContent = handoffError;
      notice.hidden = !handoffError;
    }
    const runningSummary = page.querySelector('[data-running-summary]');
    if (runningSummary) runningSummary.hidden = state.runningThreads.length === 0;
    const runningCount = page.querySelector('[data-running-count]');
    if (runningCount) {
      runningCount.textContent = String(state.runningThreads.length);
      const runningLabel = `${state.runningThreads.length} running ${state.runningThreads.length === 1 ? 'thread' : 'threads'}`;
      runningCount.parentElement?.setAttribute('aria-label', runningLabel);
      runningCount.parentElement?.setAttribute('title', runningLabel);
    }
    const runningList = page.querySelector('[data-running-list]');
    if (runningList) updateMarkup(runningList, state.runningThreads
      .map((thread) => threadMarkup.thread(thread, {
        showProject: true,
        isUnread: isThreadUnread(thread),
        compact: true,
      }))
      .join(''));
    page.querySelectorAll('[data-filter]').forEach((button) => {
      const isActive = button.dataset.filter === filterMode;
      button.classList.toggle('is-active', isActive);
      button.setAttribute('aria-pressed', String(isActive));
    });
    const filterCounts = {
      all: threads.length - state.runningThreads.length,
      unread: state.unreadCount,
      changedProjects: state.changedProjectPaths.size,
    };
    page.querySelectorAll('[data-filter-count]').forEach((count) => {
      count.textContent = String(filterCounts[count.dataset.filterCount] ?? 0);
    });
    page.querySelectorAll('[data-view]').forEach((button) => {
      const isActive = button.dataset.view === viewMode;
      button.classList.toggle('is-active', isActive);
      button.setAttribute('aria-pressed', String(isActive));
    });

    const visibleThreads = threadDashboardState.filter({
      threads,
      changedProjectPaths: state.changedProjectPaths,
      filterMode,
      searchTerm,
      isThreadUnread,
    });
    const displayedThreads = visibleThreads.slice(0, visibleThreadLimit);
    const loadedSummary = page.querySelector('[data-loaded-summary]');
    if (loadedSummary) {
      loadedSummary.hidden = displayedThreads.length >= visibleThreads.length;
      loadedSummary.textContent = displayedThreads.length < visibleThreads.length
        ? `Showing ${displayedThreads.length} of ${visibleThreads.length} matching threads.`
        : '';
    }
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
      threadMarkup.list(displayedThreads, { viewMode, collapsedProjects, isUnread: isThreadUnread }),
    );
    return true;
  }

  return { render, updateSidebarStatus };
})();
