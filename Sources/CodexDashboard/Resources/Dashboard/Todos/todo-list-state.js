const todoListState = (() => {
  const storageKey = 'codex-dashboard.todos';
  const imageDatabaseName = 'codex-dashboard.todo-images';
  const imageStoreName = 'images';
  const version = 1;

  function cleanText(value) {
    return String(value || '').trim();
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
      image: normalizeImage(item?.image, true),
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

  function save(items) {
    // An image-bearing item is not durable until both stores have accepted it.
    // Persist its binary data first: writing compact metadata first would turn an
    // IndexedDB failure into a permanently missing image after the next reload.
    const hasNewImageData = items.some((item) => item.image?.dataURL);
    if (!hasNewImageData) {
      try {
        localStorage.setItem(storageKey, documentData(items, false));
        // Deletions and text-only edits can update their small localStorage index
        // immediately. Finish pruning obsolete IndexedDB blobs in the background.
        void persistImages(items).catch(() => {});
        return true;
      } catch (_) {
        return false;
      }
    }
    return persistImages(items).then(() => {
      localStorage.setItem(storageKey, documentData(items, false));
      return true;
    }).catch(() => {
      // Older WebKit renderers can disable IndexedDB. Keep the image in the
      // primary document rather than claiming success and losing it on reload.
      try {
        localStorage.setItem(storageKey, documentData(items, true));
        return true;
      } catch (_) {
        return false;
      }
    });
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

  function persistImages(items) {
    const imageIDs = new Set(items.filter((item) => item.image).map((item) => item.id));
    const imagesWithData = items.filter((item) => item.image?.dataURL);
    return imageDatabase().then((database) => new Promise((resolve, reject) => {
      const transaction = database.transaction(imageStoreName, 'readwrite');
      const store = transaction.objectStore(imageStoreName);
      const keys = store.getAllKeys();
      keys.addEventListener('success', () => {
        keys.result.forEach((id) => {
          if (!imageIDs.has(id)) store.delete(id);
        });
        imagesWithData.forEach((item) => store.put(item.image.dataURL, item.id));
      });
      transaction.addEventListener('complete', () => { database.close(); resolve(); });
      transaction.addEventListener('abort', () => { database.close(); reject(transaction.error); });
      transaction.addEventListener('error', () => { database.close(); reject(transaction.error); });
    }));
  }

  function hydrate(items) {
    const pending = items.filter((item) => item.image && !item.image.dataURL);
    if (!pending.length) return Promise.resolve(items);
    return imageDatabase().then((database) => new Promise((resolve) => {
      const transaction = database.transaction(imageStoreName, 'readonly');
      const store = transaction.objectStore(imageStoreName);
      const hydrated = new Map();
      pending.forEach((item) => {
        const request = store.get(item.id);
        request.addEventListener('success', () => hydrated.set(item.id, request.result || ''));
      });
      transaction.addEventListener('complete', () => {
        database.close();
        resolve(items.map((item) => item.image && hydrated.has(item.id)
          ? { ...item, image: { ...item.image, dataURL: hydrated.get(item.id) } }
          : item));
      });
      transaction.addEventListener('error', () => { database.close(); resolve(items); });
    })).catch(() => items);
  }

  function create(title, body = '', image = null) {
    const now = Date.now();
    return normalizeItem({
      id: crypto.randomUUID(),
      title,
      body,
      image,
      createdAt: now,
      updatedAt: now,
    });
  }

  return { create, hydrate, load, normalizeImage, normalizeItem, save };
})();
