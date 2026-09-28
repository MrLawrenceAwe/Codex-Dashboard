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
    const projectName = String(project?.name || '').trim().toLocaleLowerCase();
    if (!projectName) return [];
    const exactPathThreads = threads.filter((thread) => String(thread.projectPath).trim() === projectID);
    if (exactPathThreads.length) {
      return exactPathThreads.map((thread) => ({ id: thread.id, title: thread.title }));
    }
    const namedThreads = threads.filter((thread) => (
      String(thread.projectName || '').trim().toLocaleLowerCase() === projectName
    ));
    const projectPaths = new Set(namedThreads.map((thread) => String(thread.projectPath).trim()));
    const matchingThreads = projectPaths.size === 1 ? namedThreads : [];
    return matchingThreads.map((thread) => ({ id: thread.id, title: thread.title }));
  }
  return { applyThreads, clear, findThread: (id) => threadsByID.get(id), threadReferencesForProject };
}
