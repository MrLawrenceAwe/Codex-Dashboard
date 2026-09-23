const taskDashboardState = (() => {
  const preferencesKey = 'codex-dashboard.task-preferences';
  const legacyPreferencesKey = 'codex-dashboard.thread-preferences';

  function loadPreferences() {
    let stored = {};
    try {
      const current = localStorage.getItem(preferencesKey);
      const legacy = current === null ? localStorage.getItem(legacyPreferencesKey) : null;
      stored = JSON.parse(current || legacy || '{}');
      const hasLegacyIndicatorPaths = Object.hasOwn(stored, 'ignoredProjectPaths')
        || Object.hasOwn(stored, 'mutedProjectPaths');
      if (hasLegacyIndicatorPaths) {
        if (!Object.hasOwn(stored, 'hiddenChangeIndicatorPaths')) {
          stored.hiddenChangeIndicatorPaths = stored.mutedProjectPaths ?? stored.ignoredProjectPaths;
        }
        delete stored.mutedProjectPaths;
        delete stored.ignoredProjectPaths;
      }
      const hasLegacyCollapsedPaths = Object.hasOwn(stored, 'collapsedProjects');
      if (hasLegacyCollapsedPaths) {
        if (!Object.hasOwn(stored, 'collapsedProjectPaths')) {
          stored.collapsedProjectPaths = stored.collapsedProjects;
        }
        delete stored.collapsedProjects;
      }
      if (legacy !== null || hasLegacyIndicatorPaths || hasLegacyCollapsedPaths) {
        localStorage.setItem(preferencesKey, JSON.stringify(stored));
        if (legacy !== null) localStorage.removeItem(legacyPreferencesKey);
      }
    } catch (_) {}
    return {
      filterMode: ['recent', 'running', 'unread', 'changedProjects'].includes(stored.filterMode)
        ? stored.filterMode : 'recent',
      collapsedProjectPaths: new Set(Array.isArray(stored.collapsedProjectPaths)
        ? stored.collapsedProjectPaths.filter((value) => typeof value === 'string') : []),
      hiddenChangeIndicatorPaths: new Set(Array.isArray(stored.hiddenChangeIndicatorPaths)
        ? stored.hiddenChangeIndicatorPaths.filter((value) => typeof value === 'string') : []),
    };
  }

  function savePreferences({ filterMode, collapsedProjectPaths, hiddenChangeIndicatorPaths }) {
    try {
      localStorage.setItem(preferencesKey, JSON.stringify({
        filterMode,
        collapsedProjectPaths: [...collapsedProjectPaths],
        hiddenChangeIndicatorPaths: [...hiddenChangeIndicatorPaths],
      }));
    } catch (_) {}
  }

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
      const matchesFilter = filterMode === 'recent'
        || (filterMode === 'running' && thread.runState === 'running')
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && allChangedProjectPaths.has(String(thread.projectPath).trim()));
      return matchesFilter;
    });
  }


  return { summarizeActivity, filter, loadPreferences, savePreferences };
})();
