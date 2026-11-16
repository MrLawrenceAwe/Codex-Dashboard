const sentMessageDictation = createSentMessageDictation();
const pushControls = createPushControls();
const threadCatalog = createThreadCatalog();
const projectGitActions = createProjectGitActions({ requestRPC: codexRPCClient.request });
const gitToolbar = createGitToolbar({
  projectGitActions,
  findThread: threadCatalog.findThread,
  prefetchRemote: pushControls.prefetchRemote,
  remoteState: pushControls.remoteState,
  subscribeRemote: pushControls.subscribeRemote,
  checkBranchAhead: pushControls.checkBranchAhead,
  checkWorkingTree: pushControls.checkWorkingTree,
  repositoryState: pushControls.repositoryState,
});
const chatOverview = createChatOverview({ catalog: threadCatalog, projectGitActions });
const todoList = createTodoList({
  ...createTodoDependencies({ store: todoStore, imageStore: todoImageStore }),
  threadReferencesForProject: threadCatalog.threadReferencesForProject,
  findThread: threadCatalog.findThread,
});
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
    sentMessageDictation.mount();
    pushControls.start();
    gitToolbar.mount();
    sidebarProjectHighlights.start();
    sidebarProjectGitIndicators.mount();
    promptLibrary.mount();
    accountPopover.mount();
  },
  rebindFeatures() {
    gitToolbar.sync();
    sidebarProjectHighlights.mount();
    sidebarProjectGitIndicators.mount();
    promptLibraryButton.scheduleSync();
  },
  syncComposer: promptLibraryButton.scheduleSync,
  requestRender: chatOverview.requestRender,
  syncUsageLimitSidebarMarkers: chatOverview.syncUsageLimitSidebarMarkers,
  syncUnread: chatOverview.syncUnread,
  destroyFeatures() {
    sentMessageDictation.destroy();
    gitToolbar.destroy();
    projectGitActions.destroy();
    pushControls.destroy();
    codexRPCClient.destroy();
    dashboardPages.forEach(({ controller }) => controller.destroy());
    sidebarProjectHighlights.destroy();
    sidebarProjectGitIndicators.destroy();
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
  editDictationStatus: sentMessageDictation.status,
  probeEditDictation: sentMessageDictation.probe,
  readPushControls: pushControls.read,
  readGitToolbar: () => dashboardNavigation.isOpen() ? 'pending' : gitToolbar.readCompatibility(),
  reviewRequest: codexRPCClient.request,
  projectRequest: codexRPCClient.request,
  pendingReviewAction: reviewLoopPage.pendingAction,
  applyReviewPageSnapshot: reviewLoopPage.applySnapshot,
  ensureMounted: ensureDashboardMounted,
  destroy() {
    dashboardLifecycle.destroy();
    threadCatalog.clear();
    delete window.__codexDashboard;
  },
  openChatOverview: () => dashboardNavigation.openPage(chatOverview),
  isOpen: dashboardNavigation.isOpen,
  openReviews: () => dashboardNavigation.openPage(reviewLoopPage),
  openTodos: () => dashboardNavigation.openPage(todoList),
  applyThreads(nextThreads) {
    threadCatalog.applyThreads(nextThreads);
    sidebarProjectGitIndicators.applyThreads(threadCatalog.currentThreads());
    gitToolbar.sync();
    chatOverview.applyThreads();
    todoList.refreshThreadOptions();
    todoList.refreshSidebarActions();
    return true;
  },
  applyAccountPopoverSnapshot: accountPopover.applySnapshot,
  readQueuedAccountPopoverAction: accountPopover.readQueuedAction,
  acknowledgeAccountPopoverAction: accountPopover.acknowledgeAction,
  completeAccountPopoverAction: accountPopover.completeAction,
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
