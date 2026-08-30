const taskDashboardState = (() => {
  const preferencesKey = 'codex-dashboard.task-preferences';
  const legacyPreferencesKey = 'codex-dashboard.thread-preferences';

  function loadPreferences() {
    let stored = {};
    try {
      const current = localStorage.getItem(preferencesKey);
      const legacy = current === null ? localStorage.getItem(legacyPreferencesKey) : null;
      stored = JSON.parse(current || legacy || '{}');
      if (legacy !== null) {
        localStorage.setItem(preferencesKey, legacy);
        localStorage.removeItem(legacyPreferencesKey);
      }
    } catch (_) {}
    return {
      filterMode: ['running', 'unread', 'changedProjects'].includes(stored.filterMode)
        ? stored.filterMode : 'running',
      collapsedProjects: new Set(Array.isArray(stored.collapsedProjects)
        ? stored.collapsedProjects.filter((value) => typeof value === 'string') : []),
      ignoredProjectPaths: new Set(Array.isArray(stored.ignoredProjectPaths)
        ? stored.ignoredProjectPaths.filter((value) => typeof value === 'string') : []),
    };
  }

  function savePreferences({ filterMode, collapsedProjects, ignoredProjectPaths }) {
    try {
      localStorage.setItem(preferencesKey, JSON.stringify({
        filterMode,
        collapsedProjects: [...collapsedProjects],
        ignoredProjectPaths: [...ignoredProjectPaths],
      }));
    } catch (_) {}
  }

  function derive(threads, isThreadUnread, ignoredProjectPaths) {
    return {
      runningThreads: threads.filter((thread) => thread.runState === 'running'),
      unreadCount: threads.filter(isThreadUnread).length,
      visibleChangedProjectPaths: new Set(
        threads
          .filter((thread) => thread.workingTreeStatus === 'hasChanges')
          .map((thread) => String(thread.projectPath).trim())
          .filter((path) => !ignoredProjectPaths.has(path)),
      ),
      allChangedProjectPaths: new Set(
        threads
          .filter((thread) => thread.workingTreeStatus === 'hasChanges')
          .map((thread) => String(thread.projectPath).trim()),
      ),
    };
  }

  function filter({
    threads,
    allChangedProjectPaths,
    filterMode,
    isThreadUnread,
  }) {
    return threads.filter((thread) => {
      const matchesFilter = (filterMode === 'running' && thread.runState === 'running')
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && allChangedProjectPaths.has(String(thread.projectPath).trim()));
      return matchesFilter;
    });
  }

  function normalizeThreads(threads) {
    return Array.isArray(threads) ? threads : [];
  }

  return { derive, filter, loadPreferences, normalizeThreads, savePreferences };
})();
