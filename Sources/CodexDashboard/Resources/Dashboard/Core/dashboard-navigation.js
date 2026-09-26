const threadCatalog = createThreadCatalog();
const taskDashboard = createTaskDashboard({ catalog: threadCatalog });
const todoList = createTodoList({ threadReferencesForProject: threadCatalog.threadReferencesForProject });
const promptLibrary = createPromptLibrary({ findThread: threadCatalog.findThread });

const dashboardNavigation = (() => {
  function applyThreads(nextThreads) {
    const threads = threadCatalog.applyThreads(nextThreads);
    taskDashboard.applyThreads(threads);
    todoList.refreshThreadOptions();
    return true;
  }

  function openTasks() {
    todoList.close();
    reviewLoopPage.close();
    taskDashboard.open();
  }

  function openTodos() {
    taskDashboard.close();
    reviewLoopPage.close();
    todoList.open();
  }

  function openReviews() {
    taskDashboard.close();
    todoList.close();
    reviewLoopPage.open();
  }

  function close() {
    taskDashboard.close();
    todoList.close();
    reviewLoopPage.close();
  }

  function isOpen() {
    return taskDashboard.isOpen() || todoList.isOpen() || reviewLoopPage.isOpen();
  }

  function mountNavigation() {
    const tasksMounted = taskDashboard.mountNavigation();
    const todosMounted = todoList.mountNavigation();
    const reviewsMounted = reviewLoopPage.mountNavigation();
    return tasksMounted && todosMounted && reviewsMounted;
  }

  function mountPages() {
    const tasksMounted = taskDashboard.mountPage();
    const todosMounted = todoList.mountPage();
    const reviewsMounted = reviewLoopPage.mount();
    return tasksMounted && todosMounted && reviewsMounted;
  }

  function applyVisibility() {
    taskDashboard.applyVisibility();
    todoList.applyVisibility();
    reviewLoopPage.applyVisibility();
  }

  function ensureMounted() {
    const mounted = dashboardLifecycle.ensureMounted({
      close,
      isOpen,
      mountNavigation,
      mountPage: mountPages,
      openTasks,
      openTodos,
      openReviews,
      applyVisibility,
      requestRender: taskDashboard.requestRender,
      syncSidebarMarkers: taskDashboard.syncSidebarMarkers,
      syncUnread: taskDashboard.syncUnread,
    });
    taskDashboard.startMonitoring();
    return mounted;
  }

  function destroy() {
    reviewLoopPage.close();
    reviewHost.destroy();
    taskDashboard.destroy();
    todoList.destroy();
    dashboardLifecycle.destroy();
    threadCatalog.clear();
    delete window.__codexDashboard;
  }

  return { applyThreads, ensureMounted, destroy, openTasks, openTodos, openReviews, isOpen, close };
})();
