const taskDashboardState = (() => {
  const preferencesKey = 'codex-dashboard.task-preferences';
  const legacyPreferencesKey = 'codex-dashboard.thread-preferences';

  function loadPreferences() {
    let stored = {};
    try {
      const current = localStorage.getItem(preferencesKey);
      const legacy = current === null ? localStorage.getItem(legacyPreferencesKey) : null;
      stored = JSON.parse(current || legacy || '{}');
      const hasLegacyMutedPaths = Object.hasOwn(stored, 'ignoredProjectPaths');
      if (hasLegacyMutedPaths) {
        if (!Object.hasOwn(stored, 'mutedProjectPaths')) {
          stored.mutedProjectPaths = stored.ignoredProjectPaths;
        }
        delete stored.ignoredProjectPaths;
      }
      const hasLegacyCollapsedPaths = Object.hasOwn(stored, 'collapsedProjects');
      if (hasLegacyCollapsedPaths) {
        if (!Object.hasOwn(stored, 'collapsedProjectPaths')) {
          stored.collapsedProjectPaths = stored.collapsedProjects;
        }
        delete stored.collapsedProjects;
      }
      if (legacy !== null || hasLegacyMutedPaths || hasLegacyCollapsedPaths) {
        localStorage.setItem(preferencesKey, JSON.stringify(stored));
        if (legacy !== null) localStorage.removeItem(legacyPreferencesKey);
      }
    } catch (_) {}
    return {
      filterMode: ['recent', 'running', 'unread', 'changedProjects'].includes(stored.filterMode)
        ? stored.filterMode : 'recent',
      collapsedProjectPaths: new Set(Array.isArray(stored.collapsedProjectPaths)
        ? stored.collapsedProjectPaths.filter((value) => typeof value === 'string') : []),
      mutedProjectPaths: new Set(Array.isArray(stored.mutedProjectPaths)
        ? stored.mutedProjectPaths.filter((value) => typeof value === 'string') : []),
    };
  }

  function savePreferences({ filterMode, collapsedProjectPaths, mutedProjectPaths }) {
    try {
      localStorage.setItem(preferencesKey, JSON.stringify({
        filterMode,
        collapsedProjectPaths: [...collapsedProjectPaths],
        mutedProjectPaths: [...mutedProjectPaths],
      }));
    } catch (_) {}
  }

  function summarizeActivity(threads, isThreadUnread, mutedProjectPaths) {
    let runningCount = 0;
    const unmutedChangedProjectPaths = new Set();
    const allChangedProjectPaths = new Set();
    let unreadCount = 0;

    threads.forEach((thread) => {
      if (thread.runState === 'running') runningCount += 1;
      if (isThreadUnread(thread)) unreadCount += 1;
      if (thread.workingTreeStatus === 'hasChanges') {
        const projectPath = String(thread.projectPath).trim();
        allChangedProjectPaths.add(projectPath);
        if (!mutedProjectPaths.has(projectPath)) unmutedChangedProjectPaths.add(projectPath);
      }
    });
    return { runningCount, unreadCount, unmutedChangedProjectPaths, allChangedProjectPaths };
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

  function sortThreadsByRecency(threads) {
    if (!Array.isArray(threads)) return [];
    return [...threads].sort((left, right) => {
      const recencyDifference = Number(right.recencyEpochMillis || 0) - Number(left.recencyEpochMillis || 0);
      return recencyDifference || String(left.id).localeCompare(String(right.id));
    });
  }

  return { summarizeActivity, filter, loadPreferences, sortThreadsByRecency, savePreferences };
})();
