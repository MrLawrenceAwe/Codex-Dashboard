function createThreadCompletionIndicators({ findThread, isThreadUnread, onChange }) {
  const indicatorDurationMs = 60_000;
  const expiryByThreadID = new Map();
  let timer;

  function scheduleExpiry() {
    if (timer !== undefined) clearTimeout(timer);
    const now = Date.now();
    const expiries = [...expiryByThreadID.values()].filter((expiry) => expiry > now);
    if (!expiries.length) {
      timer = undefined;
      return;
    }
    timer = window.setTimeout(() => {
      timer = undefined;
      onChange();
      scheduleExpiry();
    }, Math.min(...expiries) - now);
  }

  function unreadChanged(previousIDs, nextIDs) {
    previousIDs.forEach((threadID) => {
      if (nextIDs.has(threadID)) return;
      const thread = findThread(threadID);
      if (thread?.latestLifecycleEventKind === 'completed') {
        expiryByThreadID.set(threadID, Date.now() + indicatorDurationMs);
      }
    });
    nextIDs.forEach((threadID) => expiryByThreadID.delete(threadID));
    scheduleExpiry();
  }

  function isVisible(thread) {
    if (thread.latestLifecycleEventKind !== 'completed') return false;
    if (isThreadUnread(thread)) return true;
    const expiry = expiryByThreadID.get(thread.id);
    if (!expiry) return false;
    if (expiry > Date.now()) return true;
    expiryByThreadID.delete(thread.id);
    scheduleExpiry();
    return false;
  }

  function pruneMissingThreads() {
    expiryByThreadID.forEach((_, threadID) => {
      if (!findThread(threadID)) expiryByThreadID.delete(threadID);
    });
    scheduleExpiry();
  }

  function destroy() {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    expiryByThreadID.clear();
  }

  return { unreadChanged, isVisible, pruneMissingThreads, destroy };
}
