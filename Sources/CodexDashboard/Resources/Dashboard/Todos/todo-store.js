const todoStore = (() => {
  const storageKey = 'codex-dashboard.todos';
  const tagsStorageKey = 'codex-dashboard.todo-tags';
  const legacyTagsStorageKey = 'codex-dashboard.todo-badges';
  const imageDatabaseName = 'codex-dashboard.todo-images';
  const imageStoreName = 'images';
  const version = 5;
  const supportedVersions = new Set([1, 2, 3, 4, version]);
  const maximumTags = 8;
  const maximumTagLength = 40;

  function cleanText(value) {
    return String(value || '').trim();
  }

  function normalizeTags(tags) {
    if (!Array.isArray(tags)) return [];
    const seen = new Set();
    return tags.reduce((normalized, tag) => {
      const name = cleanText(tag).slice(0, maximumTagLength);
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
    const match = dataURL.match(/^data:(image\/(?:jpeg|png|gif|webp));base64,[a-z0-9+/=\s]+$/i);
    if (!match && !allowDeferredData) return null;
    const type = match?.[1]?.toLowerCase() || cleanText(image.type).toLowerCase();
    if (!acceptedImageType(type)) return null;
    return {
      dataURL,
      name: cleanText(image.name) || 'Attached image',
      type,
      size: Math.max(0, Number(image.size) || 0),
    };
  }

  function normalizeProject(project) {
    const id = cleanText(project?.id);
    const name = cleanText(project?.name).slice(0, maximumTagLength);
    return id && name ? { id, name } : null;
  }

  function acceptedImageType(type) {
    return ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(type);
  }

  function normalizeItem(item) {
    const title = cleanText(item?.title);
    const body = cleanText(item?.body);
    const id = cleanText(item?.id);
    if (!id || !title) return null;
    return {
      id,
      title,
      body,
      completed: item?.completed === true,
      tags: normalizeTags(item?.tags),
      project: normalizeProject(item?.project),
      image: normalizeImage(item?.image, true),
      createdAt: Number(item?.createdAt) || Date.now(),
      updatedAt: Number(item?.updatedAt) || Number(item?.createdAt) || Date.now(),
    };
  }

  function migrateItem(item, sourceVersion) {
    if (sourceVersion < 4) {
      return { ...item, tags: item?.badges, project: item?.projectBadge };
    }
    if (sourceVersion === 4) return { ...item, project: item?.projectTag };
    return item;
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
      if (legacy !== null) {
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

  function save(items, tags) {
    // Every write, including image pruning, completes before the next snapshot starts.
    const result = saveQueue.then(() => writeSnapshot(items, tags)).catch(() => false);
    saveQueue = result;
    return result;
  }

  async function writeSnapshot(items, tags) {
    let includesImageData = false;
    try {
      await persistImages(items);
    } catch (_) {
      // Inline storage preserves images when IndexedDB is unavailable.
      includesImageData = true;
    }
    const previousTags = localStorage.getItem(tagsStorageKey);
    try {
      localStorage.setItem(tagsStorageKey, JSON.stringify(normalizeTags(tags)));
      localStorage.setItem(storageKey, documentData(items, includesImageData));
      await pruneImages(items).catch(() => {});
      return true;
    } catch (_) {
      try {
        if (previousTags === null) localStorage.removeItem(tagsStorageKey);
        else localStorage.setItem(tagsStorageKey, previousTags);
      } catch (_) {}
      return false;
    }
  }

  function imageDatabase() {
    if (!window.indexedDB) return Promise.reject(new Error('IndexedDB is unavailable.'));
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(imageDatabaseName, 1);
      request.addEventListener('upgradeneeded', () => {
        if (!request.result.objectStoreNames.contains(imageStoreName)) {
          request.result.createObjectStore(imageStoreName);
        }
      });
      request.addEventListener('success', () => resolve(request.result));
      request.addEventListener('error', () => reject(request.error));
    });
  }

  async function withImageStore(mode, operation) {
    const database = await imageDatabase();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = database.transaction(imageStoreName, mode);
        const result = operation(transaction.objectStore(imageStoreName));
        transaction.addEventListener('complete', () => resolve(result));
        transaction.addEventListener('abort', () => reject(transaction.error));
        transaction.addEventListener('error', () => reject(transaction.error));
      });
    } finally {
      database.close();
    }
  }

  function persistImages(items) {
    return withImageStore('readwrite', (store) => {
      items.filter((item) => item.image?.dataURL)
        .forEach((item) => store.put(item.image.dataURL, item.id));
    });
  }

  function pruneImages(items) {
    const imageIDs = new Set(items.filter((item) => item.image).map((item) => item.id));
    return withImageStore('readwrite', (store) => {
      const keys = store.getAllKeys();
      keys.addEventListener('success', () => {
        keys.result.forEach((id) => { if (!imageIDs.has(id)) store.delete(id); });
      });
    });
  }

  function hydrate(items) {
    const pending = items.filter((item) => item.image && !item.image.dataURL);
    if (!pending.length) return Promise.resolve(items);
    return withImageStore('readonly', (store) => {
      const hydrated = new Map();
      pending.forEach((item) => {
        const request = store.get(item.id);
        request.addEventListener('success', () => hydrated.set(item.id, request.result || ''));
      });
      return hydrated;
    }).then((hydrated) => items.map((item) => item.image && hydrated.has(item.id)
      ? { ...item, image: { ...item.image, dataURL: hydrated.get(item.id) } }
      : item)).catch(() => items);
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

  return { create, hydrate, load, loadTags, normalizeTags, normalizeImage, normalizeItem, normalizeProject, save };
})();
