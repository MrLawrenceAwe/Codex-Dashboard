const threadDashboardState = (() => {
  const preferencesKey = 'codex-dashboard.thread-preferences';

  function loadPreferences() {
    let stored = {};
    try { stored = JSON.parse(localStorage.getItem(preferencesKey) || '{}'); } catch (_) {}
    return {
      filterMode: ['all', 'unread', 'changedProjects'].includes(stored.filterMode)
        ? stored.filterMode : 'all',
      viewMode: ['projects', 'recent'].includes(stored.viewMode)
        ? stored.viewMode : 'projects',
      collapsedProjects: new Set(Array.isArray(stored.collapsedProjects)
        ? stored.collapsedProjects.filter((value) => typeof value === 'string') : []),
      ignoredProjectPaths: new Set(Array.isArray(stored.ignoredProjectPaths)
        ? stored.ignoredProjectPaths.filter((value) => typeof value === 'string') : []),
    };
  }

  function savePreferences({ filterMode, viewMode, collapsedProjects, ignoredProjectPaths }) {
    try {
      localStorage.setItem(preferencesKey, JSON.stringify({
        filterMode,
        viewMode,
        collapsedProjects: [...collapsedProjects],
        ignoredProjectPaths: [...ignoredProjectPaths],
      }));
    } catch (_) {}
  }

  function derive(threads, isThreadUnread, ignoredProjectPaths) {
    return {
      runningThreads: threads.filter((thread) => thread.runState === 'running'),
      unreadCount: threads.filter(isThreadUnread).length,
      changedProjectPaths: new Set(
        threads
          .filter((thread) => thread.runState !== 'running' && thread.workingTreeStatus === 'hasChanges')
          .map((thread) => String(thread.projectPath).trim())
          .filter((path) => !ignoredProjectPaths.has(path)),
      ),
      dirtyProjectPaths: new Set(
        threads
          .filter((thread) => thread.workingTreeStatus === 'hasChanges')
          .map((thread) => String(thread.projectPath).trim())
          .filter((path) => !ignoredProjectPaths.has(path)),
      ),
    };
  }

  function filter({
    threads,
    changedProjectPaths,
    filterMode,
    searchTerm,
    isThreadUnread,
  }) {
    const query = searchTerm.trim().toLowerCase();
    return threads.filter((thread) => {
      if (thread.runState === 'running') return false;
      const matchesFilter = filterMode === 'all'
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && changedProjectPaths.has(String(thread.projectPath).trim()));
      const matchesSearch = !query
        || `${thread.title} ${thread.preview} ${thread.projectName} ${thread.projectPath}`
          .toLowerCase().includes(query);
      return matchesFilter && matchesSearch;
    });
  }

  function normalizeSnapshot(snapshot) {
    const threads = Array.isArray(snapshot?.threads) ? snapshot.threads : [];
    return { threads };
  }

  return { derive, filter, loadPreferences, normalizeSnapshot, savePreferences };
})();
