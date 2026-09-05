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
      if (legacy !== null || hasLegacyMutedPaths) {
        localStorage.setItem(preferencesKey, JSON.stringify(stored));
        if (legacy !== null) localStorage.removeItem(legacyPreferencesKey);
      }
    } catch (_) {}
    return {
      filterMode: ['today', 'running', 'unread', 'changedProjects'].includes(stored.filterMode)
        ? stored.filterMode : 'today',
      collapsedProjects: new Set(Array.isArray(stored.collapsedProjects)
        ? stored.collapsedProjects.filter((value) => typeof value === 'string') : []),
      mutedProjectPaths: new Set(Array.isArray(stored.mutedProjectPaths)
        ? stored.mutedProjectPaths.filter((value) => typeof value === 'string') : []),
    };
  }

  function savePreferences({ filterMode, collapsedProjects, mutedProjectPaths }) {
    try {
      localStorage.setItem(preferencesKey, JSON.stringify({
        filterMode,
        collapsedProjects: [...collapsedProjects],
        mutedProjectPaths: [...mutedProjectPaths],
      }));
    } catch (_) {}
  }

  function derive(threads, isThreadUnread, mutedProjectPaths, now = new Date()) {
    const startOfToday = new Date(now);
    startOfToday.setHours(0, 0, 0, 0);
    const startOfTomorrow = new Date(startOfToday);
    startOfTomorrow.setDate(startOfTomorrow.getDate() + 1);
    const dayRange = { start: startOfToday.getTime(), end: startOfTomorrow.getTime() };
    let runningCount = 0;
    const unmutedChangedProjectPaths = new Set();
    const allChangedProjectPaths = new Set();
    let todayCount = 0;
    let unreadCount = 0;

    threads.forEach((thread) => {
      if (isToday(thread, dayRange)) todayCount += 1;
      if (thread.runState === 'running') runningCount += 1;
      if (isThreadUnread(thread)) unreadCount += 1;
      if (thread.workingTreeStatus === 'hasChanges') {
        const projectPath = String(thread.projectPath).trim();
        allChangedProjectPaths.add(projectPath);
        if (!mutedProjectPaths.has(projectPath)) unmutedChangedProjectPaths.add(projectPath);
      }
    });
    return { todayCount, runningCount, unreadCount, unmutedChangedProjectPaths, allChangedProjectPaths, dayRange };
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

  function sortThreadsByRecency(threads) {
    if (!Array.isArray(threads)) return [];
    return [...threads].sort((left, right) => {
      const recencyDifference = Number(right.recencyEpochMillis || 0) - Number(left.recencyEpochMillis || 0);
      return recencyDifference || String(left.id).localeCompare(String(right.id));
    });
  }

  return { derive, filter, loadPreferences, sortThreadsByRecency, savePreferences };
})();
