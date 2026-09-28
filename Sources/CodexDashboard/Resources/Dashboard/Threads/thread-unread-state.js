function createThreadUnreadState({ findThread, isOpen, onChange, completionIndicators }) {
  let unreadThreadIDs = new Set();
  const sidebarUnreadOverrides = new Map();
  const observedSidebarReadStates = new Map();
  let unreadSyncTimer;
  let unreadMonitoringStarted = false;

  function unreadRevision(thread) {
    return JSON.stringify([
      thread.recencyEpochMillis, thread.runState, thread.latestLifecycleEventKind, thread.preview,
    ]);
  }

  function syncUnreadFromSidebar(nextUnreadThreadIDs = new Set(unreadThreadIDs)) {
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
        sidebarUnreadOverrides.set(id, { isUnread, revision: unreadRevision(thread) });
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
    const nextUnreadThreadIDs = new Set(
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
      if (override.isUnread) nextUnreadThreadIDs.add(id);
      else nextUnreadThreadIDs.delete(id);
    });
    completionIndicators.pruneMissingThreads();
    syncUnreadFromSidebar(nextUnreadThreadIDs);
    scheduleUnreadSync(1500);
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
    unreadMonitoringStarted = false;
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  }

  return {
    applyThreads,
    destroy,
    isThreadUnread,
    scheduleUnreadSync,
    startMonitoring,
    syncUnread: syncUnreadFromSidebar,
  };
}
