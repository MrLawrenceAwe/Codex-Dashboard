const taskDashboardQuery = (() => {
  function summarizeActivity(threads, isThreadUnread, hiddenChangeIndicatorPaths) {
    let runningCount = 0;
    const indicatedChangedProjectPaths = new Set();
    const allChangedProjectPaths = new Set();
    let unreadCount = 0;

    threads.forEach((thread) => {
      if (thread.runState === 'running') runningCount += 1;
      if (isThreadUnread(thread)) unreadCount += 1;
      if (thread.workingTreeStatus === 'hasChanges') {
        const projectPath = String(thread.projectPath).trim();
        allChangedProjectPaths.add(projectPath);
        if (!hiddenChangeIndicatorPaths.has(projectPath)) indicatedChangedProjectPaths.add(projectPath);
      }
    });
    return { runningCount, unreadCount, indicatedChangedProjectPaths, allChangedProjectPaths };
  }

  function selectThreads({
    threads,
    allChangedProjectPaths,
    filterMode,
    isThreadUnread,
    visibleItemLimit,
  }) {
    const visibleThreads = threads.filter((thread) =>
      filterMode === 'all'
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && allChangedProjectPaths.has(String(thread.projectPath).trim())));
    if (filterMode === 'changedProjects') {
      const projectPaths = [...new Set(visibleThreads.map((thread) => String(thread.projectPath).trim()))];
      const displayedProjectPaths = new Set(projectPaths.slice(0, visibleItemLimit));
      return {
        visibleThreads,
        displayedThreads: visibleThreads.filter((thread) => displayedProjectPaths.has(String(thread.projectPath).trim())),
        leadingRunningThreadCount: 0,
        hasMore: visibleItemLimit < projectPaths.length,
      };
    }
    if (filterMode === 'all') {
      const runningThreads = visibleThreads.filter((thread) => thread.runState === 'running');
      const recentThreads = visibleThreads.filter((thread) => thread.runState !== 'running');
      return {
        visibleThreads,
        displayedThreads: [...runningThreads, ...recentThreads.slice(0, visibleItemLimit)],
        leadingRunningThreadCount: runningThreads.length,
        hasMore: visibleItemLimit < recentThreads.length,
      };
    }
    return {
      visibleThreads,
      displayedThreads: visibleThreads.slice(0, visibleItemLimit),
      leadingRunningThreadCount: 0,
      hasMore: visibleItemLimit < visibleThreads.length,
    };
  }

  return { summarizeActivity, selectThreads };
})();
