const threadUsageLimitIndicators = (() => {
  function applyThreads(threads) {
    const usageLimitedThreadIDs = new Set(
      threads
        .filter((thread) => thread.latestLifecycleEventKind === 'usageLimitReached')
        .map((thread) => thread.id),
    );
    document.querySelectorAll('[data-codex-sidebar-usage-limit]').forEach((marker) => {
      const threadID = marker.dataset.codexSidebarUsageLimit;
      const row = codexUIContracts.threadRow(threadID);
      const title = codexUIContracts.sidebarThreads.titleElement(row);
      if (!usageLimitedThreadIDs.has(threadID) || !row?.contains(marker)
          || marker.parentElement !== title?.parentElement) marker.remove();
    });
    usageLimitedThreadIDs.forEach((threadID) => {
      const row = codexUIContracts.threadRow(threadID);
      if (!row) return;
      let marker = row.querySelector('[data-codex-sidebar-usage-limit]');
      if (!marker) {
        const title = codexUIContracts.sidebarThreads.titleElement(row);
        const markerHost = title?.parentElement;
        if (!markerHost) return;
        marker = document.createElement('span');
        marker.setAttribute('data-codex-sidebar-usage-limit', threadID);
        marker.textContent = 'Interrupted';
        markerHost.insertBefore(marker, title);
      }
      marker.setAttribute('role', 'status');
      marker.setAttribute('aria-label', 'Interrupted because the usage limit was reached');
      marker.setAttribute('title', 'This chat was interrupted because the usage limit was reached');
    });
  }

  function destroy() {
    document.querySelectorAll('[data-codex-sidebar-usage-limit]').forEach((marker) => marker.remove());
  }

  return { applyThreads, destroy };
})();
