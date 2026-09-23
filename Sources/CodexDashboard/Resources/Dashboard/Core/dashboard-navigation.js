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
    taskDashboard.open();
  }

  function openTodos() {
    taskDashboard.close();
    todoList.open();
  }

  function close() {
    taskDashboard.close();
    todoList.close();
  }

  function isOpen() {
    return taskDashboard.isOpen() || todoList.isOpen();
  }

  function mountNavigation() {
    const tasksMounted = taskDashboard.mountNavigation();
    const todosMounted = todoList.mountNavigation();
    return tasksMounted && todosMounted;
  }

  function mountPages() {
    const tasksMounted = taskDashboard.mountPage();
    const todosMounted = todoList.mountPage();
    return tasksMounted && todosMounted;
  }

  function applyVisibility() {
    taskDashboard.applyVisibility();
    todoList.applyVisibility();
  }

  function ensureMounted() {
    const mounted = dashboardLifecycle.ensureMounted({
      close,
      isOpen,
      mountNavigation,
      mountPage: mountPages,
      openTasks,
      openTodos,
      applyVisibility,
      requestRender: taskDashboard.requestRender,
      syncSidebarMarkers: taskDashboard.syncSidebarMarkers,
      syncUnread: taskDashboard.syncUnread,
    });
    taskDashboard.startMonitoring();
    return mounted;
  }

  function destroy() {
    taskDashboard.destroy();
    todoList.destroy();
    dashboardLifecycle.destroy();
    threadCatalog.clear();
    delete window.__codexDashboard;
  }

  return { applyThreads, ensureMounted, destroy, openTasks, openTodos, isOpen };
})();
