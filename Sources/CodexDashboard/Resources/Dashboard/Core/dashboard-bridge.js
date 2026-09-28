const threadCatalog = createThreadCatalog();
const taskDashboard = createTaskDashboard({ catalog: threadCatalog });
const todoList = createTodoList({ threadReferencesForProject: threadCatalog.threadReferencesForProject });
const promptLibrary = createPromptLibrary({ findThread: threadCatalog.findThread });
const dashboardPages = [
  { controller: taskDashboard, pageID: dashboardElements.elementIDs.taskPage,
    navigationID: dashboardElements.elementIDs.taskNavButton },
  { controller: todoList, pageID: dashboardElements.elementIDs.todoPage,
    navigationID: dashboardElements.elementIDs.todoNavButton },
  { controller: reviewLoopPage, pageID: dashboardElements.elementIDs.reviewPage,
    navigationID: dashboardElements.elementIDs.reviewNavButton },
];

window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  reviewRequest: reviewRPCClient.request,
  pendingReviewAction: reviewLoopPage.pendingAction,
  applyReviewLoop: reviewLoopPage.apply,
  ensureMounted: dashboardNavigation.ensureMounted,
  destroy() {
    reviewRPCClient.destroy();
    dashboardPages.forEach(({ controller }) => controller.destroy());
    dashboardLifecycle.destroy();
    threadCatalog.clear();
    delete window.__codexDashboard;
  },
  open: dashboardNavigation.openTasks,
  isOpen: dashboardNavigation.isOpen,
  openReviews: dashboardNavigation.openReviews,
  openTodos: dashboardNavigation.openTodos,
  applyThreads(nextThreads) {
    threadCatalog.applyThreads(nextThreads);
    taskDashboard.applyThreads();
    todoList.refreshThreadOptions();
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
return dashboardNavigation.ensureMounted();
