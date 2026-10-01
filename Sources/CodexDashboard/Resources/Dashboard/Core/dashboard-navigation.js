function createDashboardNavigation(pages) {
  function openPage(page) {
    pages.forEach(({ controller }) => {
      if (controller === page) controller.open();
      else controller.close();
    });
  }

  function close() {
    pages.forEach(({ controller }) => controller.close());
  }

  function isOpen() {
    return pages.some(({ controller }) => controller.isOpen());
  }

  return { openPage, isOpen, close };
}
