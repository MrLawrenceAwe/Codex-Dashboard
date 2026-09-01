const todoListState = (() => {
  const storageKey = 'codex-dashboard.todos';
  const version = 1;

  function cleanText(value) {
    return String(value || '').trim();
  }

  function normalizeItem(item) {
    const title = cleanText(item?.title);
    const id = cleanText(item?.id);
    if (!id || !title) return null;
    return {
      id,
      title,
      completed: item?.completed === true,
      projectPath: cleanText(item?.projectPath),
      projectName: cleanText(item?.projectName),
      createdAt: Number(item?.createdAt) || Date.now(),
      updatedAt: Number(item?.updatedAt) || Number(item?.createdAt) || Date.now(),
    };
  }

  function load() {
    try {
      const document = JSON.parse(localStorage.getItem(storageKey));
      if (document?.version !== version || !Array.isArray(document.items)) return [];
      return document.items.map(normalizeItem).filter(Boolean);
    } catch (_) {
      return [];
    }
  }

  function save(items) {
    try {
      localStorage.setItem(storageKey, JSON.stringify({ version, items }));
      return true;
    } catch (_) {
      return false;
    }
  }

  function create(title, project) {
    const now = Date.now();
    return normalizeItem({
      id: crypto.randomUUID(),
      title,
      projectPath: project?.path,
      projectName: project?.name,
      createdAt: now,
      updatedAt: now,
    });
  }

  function projectsFromThreads(threads) {
    const projects = new Map();
    (Array.isArray(threads) ? threads : []).forEach((thread) => {
      const path = cleanText(thread?.projectPath);
      if (!path || projects.has(path)) return;
      const fallbackName = path.split('/').filter(Boolean).at(-1) || path;
      projects.set(path, { path, name: cleanText(thread?.projectName) || fallbackName });
    });
    return [...projects.values()].sort((left, right) => (
      left.name.localeCompare(right.name, undefined, { sensitivity: 'base' })
        || left.path.localeCompare(right.path)
    ));
  }

  return { create, load, normalizeItem, projectsFromThreads, save };
})();
