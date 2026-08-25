const threadDashboardState = (() => {
  const preferencesKey = 'codex-dashboard.thread-preferences';

  function loadPreferences() {
    let stored = {};
    try { stored = JSON.parse(localStorage.getItem(preferencesKey) || '{}'); } catch (_) {}
    return {
      filterMode: ['all', 'running', 'unread', 'changedProjects'].includes(stored.filterMode)
        ? stored.filterMode : 'all',
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
      changedProjectPaths: new Set(
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
    allChangedProjectPaths,
    filterMode,
    searchTerm,
    isThreadUnread,
  }) {
    const query = searchTerm.trim().toLowerCase();
    return threads.filter((thread) => {
      const matchesFilter = filterMode === 'all'
        || (filterMode === 'running' && thread.runState === 'running')
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && allChangedProjectPaths.has(String(thread.projectPath).trim()));
      const matchesSearch = !query
        || `${thread.title} ${thread.preview} ${thread.projectName} ${thread.projectPath}`
          .toLowerCase().includes(query);
      return matchesFilter && matchesSearch;
    });
  }

  function normalizeSnapshot(snapshot) {
    const threads = Array.isArray(snapshot?.threads) ? snapshot.threads : [];
    const accounts = Array.isArray(snapshot?.accounts) ? snapshot.accounts.map((account) => ({
      ...account,
      usage: account?.usage && typeof account.usage === 'object' ? account.usage : null,
    })) : [];
    const activeAccountID = typeof snapshot?.activeAccountID === 'string'
      ? snapshot.activeAccountID : null;
    const activeAccountUsage = snapshot?.activeAccountUsage
      && typeof snapshot.activeAccountUsage === 'object' ? snapshot.activeAccountUsage : null;
    const accountStatusMessage = typeof snapshot?.accountStatusMessage === 'string'
      ? snapshot.accountStatusMessage : null;
    return { threads, accounts, activeAccountID, activeAccountUsage, accountStatusMessage };
  }

  return { derive, filter, loadPreferences, normalizeSnapshot, savePreferences };
})();
