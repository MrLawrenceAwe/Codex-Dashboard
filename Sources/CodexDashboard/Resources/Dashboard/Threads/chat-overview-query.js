const chatOverviewQuery = (() => {
  const gitChangeLabels = {
    uncommittedChanges: { status: 'Uncommitted', action: 'Commit' },
    unpushedCommits: { status: 'Unpushed', action: 'Push' },
    uncommittedChangesAndUnpushedCommits: { status: 'Uncommitted · Unpushed', action: 'Commit' },
  };
  const canOpenProjectGitActions = thread => thread.runState !== 'running' && thread.sharesGroupRepository;

  function projectGitActionThread(threads, projectPath) {
    const candidates = threads.filter(thread => thread.projectGroupPath === projectPath
      && canOpenProjectGitActions(thread));
    // Projectless automation runs can share the folder but open under Recents.
    // Use an assigned project chat when available, keeping recency within each group.
    return candidates.find(thread => thread.projectID) ?? candidates[0];
  }

  function summarizeActivity(threads, isThreadUnread, hiddenChangeIndicatorPaths) {
    let runningCount = 0;
    const indicatedChangedProjectPaths = new Set();
    const changedProjects = new Map();
    const seenProjectPaths = new Set();
    let unreadCount = 0;

    threads.forEach((thread) => {
      if (thread.runState === 'running') runningCount += 1;
      if (isThreadUnread(thread)) unreadCount += 1;
      const projectPath = thread.projectGroupPath;
      if (projectPath && !seenProjectPaths.has(projectPath)) {
        seenProjectPaths.add(projectPath);
        const labels = gitChangeLabels[thread.projectGitStatus];
        if (labels) {
          changedProjects.set(projectPath, labels);
          if (!hiddenChangeIndicatorPaths.has(projectPath)) indicatedChangedProjectPaths.add(projectPath);
        }
      }
    });
    return { runningCount, unreadCount, indicatedChangedProjectPaths, changedProjects };
  }

  function selectThreads({
    threads,
    changedProjects,
    filterMode,
    isThreadUnread,
    visibleItemLimit,
  }) {
    const matchingThreads = threads.filter((thread) =>
      filterMode === 'overview'
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && changedProjects.has(thread.projectGroupPath)));
    if (filterMode === 'changedProjects') {
      const projectPaths = [...new Set(matchingThreads.map((thread) => thread.projectGroupPath ?? ''))];
      const displayedProjectPaths = new Set(projectPaths.slice(0, visibleItemLimit));
      return {
        matchingThreads,
        displayedThreads: matchingThreads.filter((thread) => displayedProjectPaths.has(thread.projectGroupPath ?? '')),
        leadingRunningThreadCount: 0,
        hasMore: visibleItemLimit < projectPaths.length,
      };
    }
    if (filterMode === 'overview') {
      const runningThreads = matchingThreads.filter((thread) => thread.runState === 'running');
      const recentThreads = matchingThreads.filter((thread) => thread.runState !== 'running');
      return {
        matchingThreads,
        displayedThreads: [...runningThreads, ...recentThreads.slice(0, visibleItemLimit)],
        leadingRunningThreadCount: runningThreads.length,
        hasMore: visibleItemLimit < recentThreads.length,
      };
    }
    return {
      matchingThreads,
      displayedThreads: matchingThreads.slice(0, visibleItemLimit),
      leadingRunningThreadCount: 0,
      hasMore: visibleItemLimit < matchingThreads.length,
    };
  }

  return { summarizeActivity, selectThreads, projectGitActionThread };
})();
