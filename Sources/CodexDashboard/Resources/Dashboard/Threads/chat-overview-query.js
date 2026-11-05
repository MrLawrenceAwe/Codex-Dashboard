const chatOverviewQuery = (() => {
  const hasUncommittedChanges = thread => ['uncommittedChanges', 'uncommittedChangesAndUnpushedCommits'].includes(thread.projectGitStatus);
  const hasUnpushedCommits = thread => ['unpushedCommits', 'uncommittedChangesAndUnpushedCommits'].includes(thread.projectGitStatus);
  const hasPendingGitChanges = thread => !!thread.projectGroupPath
    && (hasUncommittedChanges(thread) || hasUnpushedCommits(thread));
  const canOpenProjectGitActions = thread => thread.runState !== 'running' && thread.sharesGroupRepository;

  function projectGitAction(threads, projectPath) {
    const projectThreads = threads.filter(thread => String(thread.projectGroupPath || '').trim() === projectPath);
    const changedThread = projectThreads.find(hasPendingGitChanges);
    if (!changedThread) return;
    const candidates = projectThreads.filter(canOpenProjectGitActions);
    // Projectless automation runs can share the folder but open under Recents.
    // Use an assigned project chat when available, keeping recency within each group.
    const thread = candidates.find(thread => thread.projectID) ?? candidates[0];
    const label = (thread ?? changedThread).projectGitStatus === 'unpushedCommits' ? 'Push' : 'Commit';
    const unavailableLabel = projectThreads.some(thread => thread.sharesGroupRepository)
      ? 'Chat running' : 'No repository chat';
    return { thread, label, unavailableLabel };
  }

  function summarizeActivity(threads, isThreadUnread, hiddenChangeIndicatorPaths) {
    let runningCount = 0;
    const indicatedChangedProjectPaths = new Set();
    const allChangedProjectPaths = new Set();
    let unreadCount = 0;

    threads.forEach((thread) => {
      if (thread.runState === 'running') runningCount += 1;
      if (isThreadUnread(thread)) unreadCount += 1;
      if (hasPendingGitChanges(thread)) {
        const projectPath = String(thread.projectGroupPath || '').trim();
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
    const matchingThreads = threads.filter((thread) =>
      filterMode === 'overview'
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && allChangedProjectPaths.has(String(thread.projectGroupPath || '').trim())));
    if (filterMode === 'changedProjects') {
      const projectPaths = [...new Set(matchingThreads.map((thread) => String(thread.projectGroupPath || '').trim()))];
      const displayedProjectPaths = new Set(projectPaths.slice(0, visibleItemLimit));
      return {
        matchingThreads,
        displayedThreads: matchingThreads.filter((thread) => displayedProjectPaths.has(String(thread.projectGroupPath || '').trim())),
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

  return { summarizeActivity, selectThreads, hasUncommittedChanges, hasUnpushedCommits, hasPendingGitChanges, projectGitAction };
})();
