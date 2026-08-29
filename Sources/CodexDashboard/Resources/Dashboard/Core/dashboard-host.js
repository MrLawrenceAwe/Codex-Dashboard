window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  ensureMounted: taskDashboard.ensureMounted,
  destroy: taskDashboard.destroy,
  open: taskDashboard.open,
  isOpen: taskDashboard.isOpen,
  applyThreads: taskDashboard.applyThreads,
  applyAccountPopoverSnapshot: accountPopover.applySnapshot,
  waitForAccountPopoverAction: accountPopover.waitForAction,
  exportPromptLibrary: () => JSON.stringify(promptStore.exportLibrary()),
  exportPendingPromptLibrary: () => {
    const library = promptStore.pendingLibrary();
    return library ? JSON.stringify(library) : null;
  },
  discardPendingPromptLibrary: () => promptStore.discardPendingLibrary(),
  acknowledgePendingPromptLibrary: (library) => promptStore.acknowledgePendingLibrary(library),
  applyPromptLibrary: (library) => {
    const changed = !promptStore.matchesLibrary(library);
    const applied = promptStore.applyLibrary(library);
    if (applied && changed) promptLibrary.refresh();
    return applied;
  },
};
return taskDashboard.ensureMounted();
