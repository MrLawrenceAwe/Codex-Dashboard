const todoStore = (() => {
  const storageKey = 'codex-dashboard.todos';
  const tagsStorageKey = 'codex-dashboard.todo-tags';
  const legacyTagsStorageKey = 'codex-dashboard.todo-badges';
  const version = 8;
  const supportedVersions = new Set([1, 2, 3, 4, 5, 6, 7, version]);
  const maximumTags = 8;
  const maximumProjectNameLength = 40;

  function cleanText(value) {
    return String(value || '').trim();
  }

  function normalizeTags(tags) {
    if (!Array.isArray(tags)) return [];
    const seen = new Set();
    return tags.reduce((normalized, tag) => {
      const name = cleanText(tag);
      const key = name.toLocaleLowerCase();
      if (!name || seen.has(key) || normalized.length === maximumTags) return normalized;
      seen.add(key);
      normalized.push(name);
      return normalized;
    }, []);
  }

  function normalizeImage(image, allowDeferredData = false) {
    if (!image || typeof image !== 'object') return null;
    const dataURL = cleanText(image.dataURL);
    const match = dataURL.match(/^data:([^;,]+);base64,[a-z0-9+/=\s]+$/i);
    if (!match && !allowDeferredData) return null;
    const type = match?.[1]?.toLowerCase() || cleanText(image.type).toLowerCase();
    if (!isAcceptedImageType(type)) return null;
    return {
      dataURL,
      name: cleanText(image.name) || 'Attached image',
      type,
      size: Math.max(0, Number(image.size) || 0),
    };
  }

  function normalizeProject(project) {
    const id = cleanText(project?.id);
    const name = cleanText(project?.name).slice(0, maximumProjectNameLength);
    return id && name ? { id, name } : null;
  }

  function normalizeThread(thread) {
    const id = cleanText(thread?.id);
    const title = cleanText(thread?.title).slice(0, 240);
    return id && title ? { id, title } : null;
  }

  function isAcceptedImageType(type) {
    return ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(type);
  }

  function normalizeItem(item) {
    const title = cleanText(item?.title);
    const body = cleanText(item?.body);
    const id = cleanText(item?.id);
    if (!id || !title) return null;
    const image = normalizeImage(item?.image, true);
    if (image) {
      // Existing documents used the to-do ID as the image key. New image data
      // gets its own key so a failed document write cannot replace that image.
      image.storageKey = cleanText(item.image.storageKey)
        || (image.dataURL ? `${id}:${crypto.randomUUID()}` : id);
    }
    return {
      id,
      title,
      body,
      completed: item?.completed === true,
      tags: normalizeTags(item?.tags),
      project: normalizeProject(item?.project),
      thread: normalizeThread(item?.thread),
      preset: composerPresets.normalize(item?.preset) || null,
      image,
      createdAt: Number(item?.createdAt) || Date.now(),
      updatedAt: Number(item?.updatedAt) || Number(item?.createdAt) || Date.now(),
    };
  }

  function migrateItem(item, sourceVersion) {
    if (sourceVersion < 7) item = { ...item, thread: item?.chat };
    if (sourceVersion < 4) {
      return { ...item, tags: item?.badges, project: item?.projectBadge };
    }
    if (sourceVersion === 4) return { ...item, project: item?.projectTag };
    return item;
  }

  function writeProtectionReason() {
    try {
      const stored = localStorage.getItem(storageKey);
      if (stored === null) return null;
      const document = JSON.parse(stored);
      if (Number.isInteger(document?.version) && document.version > version) {
        return 'These to-dos were saved by a newer dashboard version. Update the dashboard to edit them.';
      }
      if (!supportedVersions.has(document?.version) || !Array.isArray(document.items)) {
        return 'The saved to-do data could not be read. Restore it before editing to-dos.';
      }
      return null;
    } catch (_) {
      return 'The saved to-do data could not be read. Restore it before editing to-dos.';
    }
  }

  function load() {
    try {
      const document = JSON.parse(localStorage.getItem(storageKey));
      if (!supportedVersions.has(document?.version) || !Array.isArray(document.items)) return [];
      const migrated = document.items.map((item) => migrateItem(item, document.version))
        .map(normalizeItem).filter(Boolean);
      if (document.version !== version) {
        // Preserve inline image data and leave the old document intact if storage is full.
        try { localStorage.setItem(storageKey, documentData(migrated, true)); } catch (_) {}
      }
      return migrated;
    } catch (_) {
      return [];
    }
  }

  function loadTags(items = []) {
    try {
      const current = localStorage.getItem(tagsStorageKey);
      const legacy = current === null ? localStorage.getItem(legacyTagsStorageKey) : null;
      const savedTags = JSON.parse(current ?? legacy);
      const tags = normalizeTags([
        ...(Array.isArray(savedTags) ? savedTags : []),
        ...items.flatMap((item) => item.tags || []),
      ]);
      if (legacy !== null && !writeProtectionReason()) {
        try {
          localStorage.setItem(tagsStorageKey, JSON.stringify(tags));
          localStorage.removeItem(legacyTagsStorageKey);
        } catch (_) {}
      }
      return tags;
    } catch (_) {
      return normalizeTags(items.flatMap((item) => item.tags || []));
    }
  }

  function documentData(items, includesImageData) {
    return JSON.stringify({
      version,
      items: items.map((item) => ({
        ...item,
        image: item.image
          ? { ...item.image, dataURL: includesImageData ? item.image.dataURL : '' }
          : null,
      })),
    });
  }

  let saveQueue = Promise.resolve();

  function mergeItems(baseItems, desiredItems, currentItems) {
    const sameField = (key, left, right) => {
      const comparable = (value) => key === 'image' && value
        ? { ...value, dataURL: '' } : value;
      return JSON.stringify(comparable(left)) === JSON.stringify(comparable(right));
    };
    const base = new Map(baseItems.map((item) => [item.id, item]));
    const desired = new Map(desiredItems.map((item) => [item.id, item]));
    const removed = new Set(baseItems.filter((item) => !desired.has(item.id)).map((item) => item.id));
    const changed = new Map(desiredItems.filter((item) =>
      !base.has(item.id) || Object.keys(item).some((key) =>
        !sameField(key, base.get(item.id)[key], item[key])))
      .map((item) => [item.id, item]));
    const existing = currentItems.filter((item) => !removed.has(item.id))
      .map((item) => {
        const local = changed.get(item.id);
        if (!local) return item;
        const previous = base.get(item.id);
        if (!previous) return local;
        const merged = { ...item };
        for (const key of Object.keys(local)) {
          if (!sameField(key, previous[key], local[key])) {
            merged[key] = key === 'tags'
              ? mergeTags(previous.tags, local.tags, item.tags) : local[key];
          }
        }
        return merged;
      });
    const existingIDs = new Set(existing.map((item) => item.id));
    const added = desiredItems.filter((item) => changed.has(item.id) && !existingIDs.has(item.id));
    return [...added, ...existing];
  }

  function mergeTags(baseTags, desiredTags, currentTags) {
    return normalizeTags([
      ...desiredTags,
      ...currentTags.filter((tag) => !baseTags.includes(tag)),
    ]);
  }

  function save(items, tags, baseItems = load(), baseTags = loadTags(baseItems)) {
    // Every write, including image pruning, completes before the next snapshot starts.
    const snapshot = items.map(normalizeItem).filter(Boolean);
    const base = baseItems.map(normalizeItem).filter(Boolean);
    const result = saveQueue.then(() => {
      const write = () => writeSnapshot(snapshot, tags, base, baseTags);
      return navigator.locks?.request
        ? navigator.locks.request(storageKey, write) : write();
    }).catch(() => false);
    saveQueue = result;
    return result;
  }

  async function writeSnapshot(items, tags, baseItems, baseTags) {
    if (writeProtectionReason()) return false;
    let includesImageData = false;
    try {
      await todoImageStore.persist(items);
    } catch (_) {
      // Inline storage preserves images when IndexedDB is unavailable.
      includesImageData = true;
    }
    // Read the shared document after the asynchronous image write, immediately
    // before replacing it, so edits from other windows are included.
    const currentItems = load();
    const mergedItems = mergeItems(baseItems, items, currentItems);
    // Inline data that is still in memory; keep unresolved image keys for later loading.
    const availableImageData = new Map(items.filter((item) => item.image?.dataURL)
      .map((item) => [item.image.storageKey, item.image.dataURL]));
    const persistedItems = mergedItems.map((item) => {
      if (!item.image) return item;
      // Only strip data for images this save actually wrote to IndexedDB.
      // Inline images merged from other windows must keep their fallback data.
      const dataURL = !includesImageData && availableImageData.has(item.image.storageKey)
        ? '' : item.image.dataURL || availableImageData.get(item.image.storageKey) || '';
      return { ...item, image: { ...item.image, dataURL } };
    });
    const mergedTags = mergeTags(baseTags, normalizeTags(tags), loadTags(currentItems));
    const previousTags = localStorage.getItem(tagsStorageKey);
    try {
      if (writeProtectionReason()) return false;
      localStorage.setItem(tagsStorageKey, JSON.stringify(mergedTags));
      localStorage.setItem(storageKey, documentData(persistedItems, true));
      await todoImageStore.prune(mergedItems).catch(() => {});
      return true;
    } catch (_) {
      try {
        if (previousTags === null) localStorage.removeItem(tagsStorageKey);
        else localStorage.setItem(tagsStorageKey, previousTags);
      } catch (_) {}
      return false;
    }
  }

  function create(title, body = '', image = null, tags = []) {
    const now = Date.now();
    return normalizeItem({
      id: crypto.randomUUID(),
      title,
      body,
      image,
      tags,
      createdAt: now,
      updatedAt: now,
    });
  }

  return { create, load, loadTags, storageKey, tagsStorageKey, maximumTags, isAcceptedImageType, normalizeTags, normalizeImage, normalizeItem, normalizeProject, normalizeThread, save, writeProtectionReason };
})();
