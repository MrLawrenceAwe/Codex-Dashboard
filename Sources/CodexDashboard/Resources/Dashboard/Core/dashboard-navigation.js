const dashboardNavigation = (() => {
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
      syncInterruptedSidebarMarkers: taskDashboard.syncInterruptedSidebarMarkers,
      syncUnread: taskDashboard.syncUnread,
      pages: dashboardPages,
    });
    taskDashboard.startMonitoring();
    return mounted;
  }

  return { ensureMounted, openTasks, openTodos, openReviews, isOpen, close };
})();
