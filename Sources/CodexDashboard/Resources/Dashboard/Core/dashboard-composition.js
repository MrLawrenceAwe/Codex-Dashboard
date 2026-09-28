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

const dashboardComposition = {
  applyThreads(nextThreads) {
    const threads = threadCatalog.applyThreads(nextThreads);
    taskDashboard.applyThreads(threads);
    todoList.refreshThreadOptions();
    return true;
  },
  destroy() {
    reviewRPCClient.destroy();
    dashboardPages.forEach(({ controller }) => controller.destroy());
    dashboardLifecycle.destroy();
    threadCatalog.clear();
    delete window.__codexDashboard;
  },
};
