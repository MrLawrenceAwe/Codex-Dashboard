function createThreadUnreadState({ findThread, isOpen, onChange, completionIndicators }) {
  const sidebarOverrideLifetimeMillis = 10_000;
  let unreadThreadIDs = new Set();
  let persistedUnreadThreadIDs = new Set();
  const sidebarUnreadOverrides = new Map();
  const observedSidebarReadStates = new Map();
  let unreadSyncTimer;
  let unreadMonitoringStarted = false;

  function unreadRevision(thread) {
    return JSON.stringify([
      thread.recencyEpochMillis, thread.runState, thread.latestLifecycleEventKind, thread.preview,
    ]);
  }

  function expireSidebarOverrides() {
    const now = Date.now();
    sidebarUnreadOverrides.forEach((override, id) => {
      if (override.expiresAt <= now) sidebarUnreadOverrides.delete(id);
    });
  }

  function syncUnreadFromSidebar() {
    expireSidebarOverrides();
    const nextUnreadThreadIDs = new Set(persistedUnreadThreadIDs);
    sidebarUnreadOverrides.forEach((override, id) => {
      if (override.isUnread) nextUnreadThreadIDs.add(id);
      else nextUnreadThreadIDs.delete(id);
    });
    const readStates = codexHost.threadReadStates();
    observedSidebarReadStates.forEach((_, id) => {
      if (!readStates.has(id) || !findThread(id)) observedSidebarReadStates.delete(id);
    });
    readStates.forEach((isUnread, id) => {
      const thread = findThread(id);
      if (!thread) return;
      const isNewObservation = observedSidebarReadStates.get(id) !== isUnread;
      observedSidebarReadStates.set(id, isUnread);
      if (isUnread === (thread.isUnread === true)) sidebarUnreadOverrides.delete(id);
      else if (isNewObservation) {
        sidebarUnreadOverrides.set(id, {
          isUnread,
          revision: unreadRevision(thread),
          expiresAt: Date.now() + sidebarOverrideLifetimeMillis,
        });
      }
      // An unchanged mounted row is not a new observation. Once its override
      // expires or is acknowledged, it must not mask a later persisted change.
      const effectiveUnread = sidebarUnreadOverrides.get(id)?.isUnread ?? (thread.isUnread === true);
      if (effectiveUnread) nextUnreadThreadIDs.add(id);
      else nextUnreadThreadIDs.delete(id);
    });
    return updateUnreadThreadIDs(nextUnreadThreadIDs);
  }

  function updateUnreadThreadIDs(nextUnreadThreadIDs) {
    let changed = false;
    unreadThreadIDs.forEach((threadID) => {
      if (nextUnreadThreadIDs.has(threadID)) return;
      changed = true;
    });
    nextUnreadThreadIDs.forEach((threadID) => {
      if (!unreadThreadIDs.has(threadID)) changed = true;
    });
    completionIndicators.unreadChanged(unreadThreadIDs, nextUnreadThreadIDs);
    unreadThreadIDs = nextUnreadThreadIDs;
    return changed;
  }

  function refreshUnreadFromSidebar() {
    if (syncUnreadFromSidebar()) onChange();
  }

  function unreadSyncDelay() {
    if (document.visibilityState === 'hidden') return 30000;
    return isOpen() ? 3000 : 10000;
  }

  function scheduleUnreadSync(delay = unreadSyncDelay()) {
    if (unreadSyncTimer !== undefined) clearTimeout(unreadSyncTimer);
    unreadSyncTimer = window.setTimeout(() => {
      unreadSyncTimer = undefined;
      refreshUnreadFromSidebar();
      scheduleUnreadSync();
    }, delay);
  }

  function handleVisibilityChange() {
    scheduleUnreadSync(document.visibilityState === 'hidden' ? unreadSyncDelay() : 0);
  }

  function isThreadUnread(thread) {
    return unreadThreadIDs.has(thread.id);
  }

  function applyThreads(threads) {
    expireSidebarOverrides();
    persistedUnreadThreadIDs = new Set(
      threads.filter((thread) => thread.isUnread === true).map((thread) => thread.id),
    );
    sidebarUnreadOverrides.forEach((override, id) => {
      const thread = findThread(id);
      // Retain live observations through persistence lag, but release them when
      // acknowledged, removed, or superseded by activity in a subsequent turn.
      if (!thread || override.isUnread === (thread.isUnread === true)
        || override.revision !== unreadRevision(thread)) {
        sidebarUnreadOverrides.delete(id);
        return;
      }
    });
    completionIndicators.pruneMissingThreads();
    syncUnreadFromSidebar();
    scheduleUnreadSync(1500);
  }

  function markReadRequested(ids) {
    ids.forEach((id) => {
      if (sidebarUnreadOverrides.get(id)?.isUnread === true) sidebarUnreadOverrides.delete(id);
    });
  }

  function startMonitoring() {
    if (!unreadMonitoringStarted) {
      unreadMonitoringStarted = true;
      scheduleUnreadSync();
      document.addEventListener('visibilitychange', handleVisibilityChange);
    }
  }

  function destroy() {
    if (unreadSyncTimer !== undefined) clearTimeout(unreadSyncTimer);
    unreadSyncTimer = undefined;
    sidebarUnreadOverrides.clear();
    observedSidebarReadStates.clear();
    unreadThreadIDs.clear();
    persistedUnreadThreadIDs.clear();
    unreadMonitoringStarted = false;
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  }

  return {
    applyThreads,
    destroy,
    isThreadUnread,
    markReadRequested,
    scheduleUnreadSync,
    startMonitoring,
    syncUnread: syncUnreadFromSidebar,
  };
}
