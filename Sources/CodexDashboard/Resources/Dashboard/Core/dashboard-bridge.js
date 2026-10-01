const threadCatalog = createThreadCatalog();
const taskDashboard = createTaskDashboard({ catalog: threadCatalog });
const todoList = createTodoList({ threadReferencesForProject: threadCatalog.threadReferencesForProject, findThread: threadCatalog.findThread });
const promptLibrary = createPromptLibrary({ findThread: threadCatalog.findThread });
const dashboardPages = [
  { controller: taskDashboard, pageID: dashboardElements.elementIDs.taskPage,
    navigationID: dashboardElements.elementIDs.taskNavButton },
  { controller: todoList, pageID: dashboardElements.elementIDs.todoPage,
    navigationID: dashboardElements.elementIDs.todoNavButton },
  { controller: reviewLoopPage, pageID: dashboardElements.elementIDs.reviewPage,
    navigationID: dashboardElements.elementIDs.reviewNavButton },
];
const dashboardNavigation = createDashboardNavigation(dashboardPages);
const dashboardLifecycle = createDashboardLifecycle({
  ...dashboardNavigation,
  pages: dashboardPages,
  mountPages() {
    dashboardPages.forEach(({ controller }) => controller.mountPage());
    dashboardPages.forEach(({ controller }) => controller.mountNavigation());
  },
  mountFeatures() {
    sidebarProjectHighlights.start();
    promptLibrary.mount();
    accountPopover.mount();
  },
  rebindFeatures() {
    sidebarProjectHighlights.mount();
    promptLibraryButton.scheduleSync();
  },
  syncComposer: promptLibraryButton.scheduleSync,
  requestRender: taskDashboard.requestRender,
  syncInterruptedSidebarMarkers: taskDashboard.syncInterruptedSidebarMarkers,
  syncUnread: taskDashboard.syncUnread,
  destroyFeatures() {
    reviewRPCClient.destroy();
    dashboardPages.forEach(({ controller }) => controller.destroy());
    sidebarProjectHighlights.destroy();
    promptLibrary.unmount();
    accountPopover.unmount();
  },
});

function ensureDashboardMounted() {
  const mounted = dashboardLifecycle.ensureMounted();
  taskDashboard.startMonitoring();
  return mounted;
}

window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  reviewRequest: reviewRPCClient.request,
  pendingReviewAction: reviewLoopPage.pendingAction,
  applyReviewLoop: reviewLoopPage.apply,
  ensureMounted: ensureDashboardMounted,
  destroy() {
    dashboardLifecycle.destroy();
    threadCatalog.clear();
    delete window.__codexDashboard;
  },
  open: () => dashboardNavigation.openPage(taskDashboard),
  isOpen: dashboardNavigation.isOpen,
  openReviews: () => dashboardNavigation.openPage(reviewLoopPage),
  openTodos: () => dashboardNavigation.openPage(todoList),
  applyThreads(nextThreads) {
    threadCatalog.applyThreads(nextThreads);
    taskDashboard.applyThreads();
    todoList.refreshThreadOptions();
    todoList.refreshSidebarActions();
    return true;
  },
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
return ensureDashboardMounted();
