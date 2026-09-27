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

const dashboardNavigation = (() => {
  function applyThreads(nextThreads) {
    const threads = threadCatalog.applyThreads(nextThreads);
    taskDashboard.applyThreads(threads);
    todoList.refreshThreadOptions();
    return true;
  }

  function openPage(page) {
    dashboardPages.forEach(({ controller }) => {
      if (controller === page) controller.open();
      else controller.close();
    });
  }

  function openTasks() { openPage(taskDashboard); }
  function openTodos() { openPage(todoList); }
  function openReviews() { openPage(reviewLoopPage); }

  function close() {
    dashboardPages.forEach(({ controller }) => controller.close());
  }

  function isOpen() {
    return dashboardPages.some(({ controller }) => controller.isOpen());
  }

  function mountNavigation() {
    return dashboardPages.map(({ controller }) => controller.mountNavigation()).every(Boolean);
  }

  function mountPages() {
    return dashboardPages.map(({ controller }) => controller.mountPage()).every(Boolean);
  }

  function applyVisibility() {
    dashboardPages.forEach(({ controller }) => controller.applyVisibility());
  }

  function ensureMounted() {
    const mounted = dashboardLifecycle.ensureMounted({
      close,
      isOpen,
      mountNavigation,
      mountPage: mountPages,
      openPage,
      applyVisibility,
      requestRender: taskDashboard.requestRender,
      syncSidebarMarkers: taskDashboard.syncSidebarMarkers,
      syncUnread: taskDashboard.syncUnread,
      pages: dashboardPages,
    });
    taskDashboard.startMonitoring();
    return mounted;
  }

  function destroy() {
    reviewLoopPage.close();
    reviewRPCClient.destroy();
    taskDashboard.destroy();
    todoList.destroy();
    dashboardLifecycle.destroy();
    threadCatalog.clear();
    delete window.__codexDashboard;
  }

  return { applyThreads, ensureMounted, destroy, openTasks, openTodos, openReviews, isOpen, close };
})();
