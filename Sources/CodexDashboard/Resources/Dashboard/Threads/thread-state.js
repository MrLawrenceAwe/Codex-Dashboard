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
    };
  }

  function savePreferences({ filterMode, viewMode, collapsedProjects }) {
    try {
      localStorage.setItem(preferencesKey, JSON.stringify({
        filterMode,
        viewMode,
        collapsedProjects: [...collapsedProjects],
      }));
    } catch (_) {}
  }

  function derive(threads, isThreadUnread) {
    return {
      runningThreads: threads.filter((thread) => thread.runState === 'running'),
      unreadCount: threads.filter(isThreadUnread).length,
      changedProjectPaths: new Set(
        threads
          .filter((thread) => thread.runState !== 'running' && thread.workingTreeStatus === 'hasChanges')
          .map((thread) => String(thread.projectPath).trim()),
      ),
      dirtyProjectPaths: new Set(
        threads
          .filter((thread) => thread.workingTreeStatus === 'hasChanges')
          .map((thread) => String(thread.projectPath).trim()),
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
    const totalThreadCount = Number.isFinite(snapshot?.totalThreadCount)
      ? Math.max(threads.length, snapshot.totalThreadCount)
      : threads.length;
    return { threads, totalThreadCount };
  }

  return { derive, filter, loadPreferences, normalizeSnapshot, savePreferences };
})();
