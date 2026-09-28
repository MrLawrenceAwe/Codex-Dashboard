const todoImageStore = (() => {
  const databaseName = 'codex-dashboard.todo-images';
  const storeName = 'images';

  function openDatabase() {
    if (!window.indexedDB) return Promise.reject(new Error('IndexedDB is unavailable.'));
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(databaseName, 1);
      request.addEventListener('upgradeneeded', () => {
        if (!request.result.objectStoreNames.contains(storeName)) {
          request.result.createObjectStore(storeName);
        }
      });
      request.addEventListener('success', () => resolve(request.result));
      request.addEventListener('error', () => reject(request.error));
    });
  }

  async function withStore(mode, operation) {
    const database = await openDatabase();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = database.transaction(storeName, mode);
        const result = operation(transaction.objectStore(storeName));
        transaction.addEventListener('complete', () => resolve(result));
        transaction.addEventListener('abort', () => reject(transaction.error));
        transaction.addEventListener('error', () => reject(transaction.error));
      });
    } finally {
      database.close();
    }
  }

  function persist(items) {
    return withStore('readwrite', (store) => {
      items.filter((item) => item.image?.dataURL)
        .forEach((item) => store.put(item.image.dataURL, item.image.storageKey));
    });
  }

  function prune(items) {
    const imageIDs = new Set(items.filter((item) => item.image)
      .map((item) => item.image.storageKey));
    return withStore('readwrite', (store) => {
      const keys = store.getAllKeys();
      keys.addEventListener('success', () => {
        keys.result.forEach((id) => { if (!imageIDs.has(id)) store.delete(id); });
      });
    });
  }

  function load(items) {
    const pending = items.filter((item) => item.image && !item.image.dataURL);
    if (!pending.length) return Promise.resolve(items);
    return withStore('readonly', (store) => {
      const hydrated = new Map();
      pending.forEach((item) => {
        const request = store.get(item.image.storageKey);
        request.addEventListener('success', () => hydrated.set(item.id, request.result || ''));
      });
      return hydrated;
    }).then((hydrated) => items.map((item) => item.image && hydrated.has(item.id)
      ? { ...item, image: { ...item.image, dataURL: hydrated.get(item.id) } }
      : item)).catch(() => items);
  }

  return { persist, prune, load };
})();
