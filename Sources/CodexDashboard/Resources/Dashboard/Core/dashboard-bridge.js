const threadCatalog = createThreadCatalog();
const chatOverview = createChatOverview({ catalog: threadCatalog });
const todoList = createTodoList({ threadReferencesForProject: threadCatalog.threadReferencesForProject, findThread: threadCatalog.findThread });
const promptLibrary = createPromptLibrary({ findThread: threadCatalog.findThread });
const dashboardPages = [
  { controller: chatOverview, pageID: dashboardElements.elementIDs.chatOverviewPage,
    navigationID: dashboardElements.elementIDs.chatOverviewNavButton },
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
  requestRender: chatOverview.requestRender,
  syncInterruptedSidebarMarkers: chatOverview.syncInterruptedSidebarMarkers,
  syncUnread: chatOverview.syncUnread,
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
  chatOverview.startMonitoring();
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
  open: () => dashboardNavigation.openPage(chatOverview),
  isOpen: dashboardNavigation.isOpen,
  openReviews: () => dashboardNavigation.openPage(reviewLoopPage),
  openTodos: () => dashboardNavigation.openPage(todoList),
  applyThreads(nextThreads) {
    threadCatalog.applyThreads(nextThreads);
    chatOverview.applyThreads();
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
