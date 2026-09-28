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

  function filter({
    threads,
    allChangedProjectPaths,
    filterMode,
    isThreadUnread,
  }) {
    return threads.filter((thread) => {
      const matchesFilter = filterMode === 'all'
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && allChangedProjectPaths.has(String(thread.projectPath).trim()));
      return matchesFilter;
    });
  }


  return { summarizeActivity, filter };
})();
