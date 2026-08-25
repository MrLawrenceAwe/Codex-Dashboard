window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  ensureMounted: threadDashboard.ensureMounted,
  destroy: threadDashboard.destroy,
  open: threadDashboard.open,
  isOpen: threadDashboard.isOpen,
  applySnapshot: threadDashboard.applySnapshot,
  consumeAccountAction: threadDashboard.consumeAccountAction,
  exportPromptLibrary: () => JSON.stringify(promptStore.exportLibrary()),
  applyPromptLibrary: (library) => {
    const applied = promptStore.applyLibrary(library);
    if (applied) promptLibrary.refresh();
    return applied;
  },
};
return threadDashboard.ensureMounted();
