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
      filterMode: ['today', 'running', 'unread', 'changedProjects'].includes(stored.filterMode)
        ? stored.filterMode : 'today',
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

  function derive(threads, isThreadUnread, ignoredProjectPaths, now = new Date()) {
    const startOfToday = new Date(now);
    startOfToday.setHours(0, 0, 0, 0);
    const startOfTomorrow = new Date(startOfToday);
    startOfTomorrow.setDate(startOfTomorrow.getDate() + 1);
    const dayRange = { start: startOfToday.getTime(), end: startOfTomorrow.getTime() };
    const runningThreads = [];
    const visibleChangedProjectPaths = new Set();
    const allChangedProjectPaths = new Set();
    let todayCount = 0;
    let unreadCount = 0;

    threads.forEach((thread) => {
      if (isToday(thread, dayRange)) todayCount += 1;
      if (thread.runState === 'running') runningThreads.push(thread);
      if (isThreadUnread(thread)) unreadCount += 1;
      if (thread.workingTreeStatus === 'hasChanges') {
        const projectPath = String(thread.projectPath).trim();
        allChangedProjectPaths.add(projectPath);
        if (!ignoredProjectPaths.has(projectPath)) visibleChangedProjectPaths.add(projectPath);
      }
    });
    return { todayCount, runningThreads, unreadCount, visibleChangedProjectPaths, allChangedProjectPaths, dayRange };
  }

  function filter({
    threads,
    allChangedProjectPaths,
    dayRange,
    filterMode,
    isThreadUnread,
  }) {
    return threads.filter((thread) => {
      const matchesFilter = (filterMode === 'today' && isToday(thread, dayRange))
        || (filterMode === 'running' && thread.runState === 'running')
        || (filterMode === 'unread' && isThreadUnread(thread))
        || (filterMode === 'changedProjects'
          && allChangedProjectPaths.has(String(thread.projectPath).trim()));
      return matchesFilter;
    });
  }

  function isToday(thread, { start, end }) {
    const recency = Number(thread.recencyEpochMillis || 0);
    if (!Number.isFinite(recency)) return false;
    return recency >= start && recency < end;
  }

  function normalizeThreads(threads) {
    if (!Array.isArray(threads)) return [];
    return [...threads].sort((left, right) => {
      const recencyDifference = Number(right.recencyEpochMillis || 0) - Number(left.recencyEpochMillis || 0);
      return recencyDifference || String(left.id).localeCompare(String(right.id));
    });
  }

  return { derive, filter, loadPreferences, normalizeThreads, savePreferences };
})();
