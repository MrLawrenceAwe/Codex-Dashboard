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

  function create(title) {
    const now = Date.now();
    return normalizeItem({
      id: crypto.randomUUID(),
      title,
      createdAt: now,
      updatedAt: now,
    });
  }

  return { create, load, normalizeItem, save };
})();
