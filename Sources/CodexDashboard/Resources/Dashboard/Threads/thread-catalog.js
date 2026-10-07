function createThreadCatalog() {
  let threads = [];
  let threadsByID = new Map();

  function applyThreads(nextThreads) {
    threads = nextThreads;
    threadsByID = new Map(threads.map((thread) => [thread.id, thread]));
    return threads;
  }

  function clear() {
    threads = [];
    threadsByID.clear();
  }

  function threadReferencesForProject(project) {
    const projectID = String(project?.id || '').trim();
    if (!projectID) return [];
    return threads.filter((thread) => thread.projectID === projectID)
      .map((thread) => ({ id: thread.id, title: thread.title }));
  }
  return { applyThreads, clear, currentThreads: () => threads, findThread: (id) => threadsByID.get(id), threadReferencesForProject };
}
