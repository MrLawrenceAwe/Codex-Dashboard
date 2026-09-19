const promptLibrary = createPromptLibrary({ findThread: taskDashboard.findThread });

const dashboardNavigation = (() => {
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
    delete window.__codexDashboard;
  }

  return { ensureMounted, destroy, openTasks, openTodos, isOpen };
})();
