const threadInterruptionIndicators = (() => {
  function applyThreads(threads) {
    const nextInterruptedThreadIDs = new Set(
      threads
        .filter((thread) => thread.latestLifecycleEventKind === 'usageLimitReached')
        .map((thread) => thread.id),
    );
    document.querySelectorAll('[data-codex-sidebar-interrupted]').forEach((marker) => {
      const threadID = marker.dataset.codexSidebarInterrupted;
      const row = codexUIContracts.threadRow(threadID);
      const title = row?.querySelector('[data-thread-title-trigger]');
      if (!nextInterruptedThreadIDs.has(threadID) || !row?.contains(marker)
          || marker.parentElement !== title?.parentElement) marker.remove();
    });
    nextInterruptedThreadIDs.forEach((threadID) => {
      const row = codexUIContracts.threadRow(threadID);
      if (!row) return;
      let marker = row.querySelector('[data-codex-sidebar-interrupted]');
      if (!marker) {
        const title = row.querySelector('[data-thread-title-trigger]');
        const markerHost = title?.parentElement;
        if (!markerHost) return;
        marker = document.createElement('span');
        marker.setAttribute('data-codex-sidebar-interrupted', threadID);
        marker.textContent = 'Interrupted';
        markerHost.insertBefore(marker, title);
      }
      marker.setAttribute('role', 'status');
      marker.setAttribute('aria-label', 'Interrupted because the usage limit was reached');
      marker.setAttribute('title', 'This chat was interrupted because the usage limit was reached');
    });
  }

  function destroy() {
    document.querySelectorAll('[data-codex-sidebar-interrupted]').forEach((marker) => marker.remove());
  }

  return { applyThreads, destroy };
})();
