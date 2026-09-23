window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  ensureMounted: dashboardNavigation.ensureMounted,
  destroy: dashboardNavigation.destroy,
  open: dashboardNavigation.openTasks,
  isOpen: dashboardNavigation.isOpen,
  openTodos: dashboardNavigation.openTodos,
  applyThreads: dashboardNavigation.applyThreads,
  applyAccountPopoverSnapshot: accountPopover.applySnapshot,
  takeNextAccountPopoverAction: accountPopover.takeNextAction,
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
return dashboardNavigation.ensureMounted();
