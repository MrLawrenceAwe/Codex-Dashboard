function createThreadUnreadState({ isOpen, onChange }) {
  let threadsByID = new Map();
  let unreadThreadIDs = new Set();
  const sidebarUnreadOverrides = new Map();
  const observedSidebarReadStates = new Map();
  const completedTickDuration = 60_000;
  const completedTickExpiryByThreadID = new Map();
  let completedTickTimer;
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
      if (!readStates.has(id) || !threadsByID.has(id)) observedSidebarReadStates.delete(id);
    });
    readStates.forEach((isUnread, id) => {
      const thread = threadsByID.get(id);
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
      const thread = threadsByID.get(threadID);
      if (thread?.latestLifecycleEventKind === 'completed') {
        completedTickExpiryByThreadID.set(threadID, Date.now() + completedTickDuration);
      }
    });
    nextUnreadThreadIDs.forEach((threadID) => {
      if (!unreadThreadIDs.has(threadID)) changed = true;
      completedTickExpiryByThreadID.delete(threadID);
    });
    unreadThreadIDs = nextUnreadThreadIDs;
    scheduleCompletedTickExpiry();
    return changed;
  }

  function isCompletionTickVisible(thread) {
    if (thread.latestLifecycleEventKind !== 'completed') return false;
    if (isThreadUnread(thread)) return true;
    const expiry = completedTickExpiryByThreadID.get(thread.id);
    if (!expiry) return false;
    if (expiry > Date.now()) return true;
    completedTickExpiryByThreadID.delete(thread.id);
    scheduleCompletedTickExpiry();
    return false;
  }

  function scheduleCompletedTickExpiry() {
    if (completedTickTimer !== undefined) clearTimeout(completedTickTimer);
    const now = Date.now();
    const expiries = [...completedTickExpiryByThreadID.values()].filter((expiry) => expiry > now);
    if (!expiries.length) {
      completedTickTimer = undefined;
      return;
    }
    completedTickTimer = window.setTimeout(() => {
      completedTickTimer = undefined;
      onChange();
      scheduleCompletedTickExpiry();
    }, Math.min(...expiries) - now);
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
    threadsByID = new Map(threads.map((thread) => [thread.id, thread]));
    sidebarUnreadOverrides.forEach((override, id) => {
      const thread = threadsByID.get(id);
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
    completedTickExpiryByThreadID.forEach((_, threadID) => {
      if (!threadsByID.has(threadID)) completedTickExpiryByThreadID.delete(threadID);
    });
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
    if (completedTickTimer !== undefined) clearTimeout(completedTickTimer);
    unreadSyncTimer = undefined;
    completedTickTimer = undefined;
    completedTickExpiryByThreadID.clear();
    sidebarUnreadOverrides.clear();
    observedSidebarReadStates.clear();
    unreadThreadIDs.clear();
    threadsByID.clear();
    unreadMonitoringStarted = false;
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  }

  return {
    applyThreads,
    destroy,
    findThread: (id) => threadsByID.get(id),
    isThreadUnread,
    isCompletionTickVisible,
    scheduleUnreadSync,
    startMonitoring,
    syncUnread: syncUnreadFromSidebar,
  };
}
