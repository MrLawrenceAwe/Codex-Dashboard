window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  ensureMounted: threadDashboard.ensureMounted,
  destroy: threadDashboard.destroy,
  open: threadDashboard.open,
  isOpen: threadDashboard.isOpen,
  applySnapshot: threadDashboard.applySnapshot,
  consumeAccountAction: threadDashboard.consumeAccountAction,
  exportPromptLibrary: () => JSON.stringify(promptStore.exportLibrary()),
  exportPendingPromptLibrary: () => {
    const library = promptStore.pendingLibrary();
    return library ? JSON.stringify(library) : null;
  },
  acknowledgePendingPromptLibrary: (library) => promptStore.acknowledgePendingLibrary(library),
  applyPromptLibrary: (library) => {
    const applied = promptStore.applyLibrary(library);
    if (applied) promptLibrary.refresh();
    return applied;
  },
};
return threadDashboard.ensureMounted();
