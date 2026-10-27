function createTodoDependencies({ store, imageStore }) {
  function trackOperations() {
    const pending = new Set();
    return {
      run(operation) {
        const promise = operation();
        pending.add(promise);
        const finished = () => pending.delete(promise);
        void promise.then(finished, finished);
        return promise;
      },
      async wait() {
        while (pending.size) await Promise.all([...pending]);
        await Promise.resolve();
      },
    };
  }

  const saves = trackOperations();
  const transfers = trackOperations();
  window.__todoStoreForTests = store;
  window.__todoImageStoreForTests = imageStore;
  window.__waitForTodoSaves = saves.wait;
  window.__waitForTodoTransfers = transfers.wait;
  return { store, runSave: saves.run, runTransfer: transfers.run };
}
