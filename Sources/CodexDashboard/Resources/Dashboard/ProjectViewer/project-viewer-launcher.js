const projectViewerLauncher = (() => {
  const requestPrefix = [...crypto.getRandomValues(new Uint32Array(4))].join('-');
  let requestCount = 0;
  let request = null;
  let expiry;
  function open(path, { projectID, threadID } = {}) {
    if (typeof path !== 'string' || !path.startsWith('/')) return false;
    request = { id: requestPrefix + '-' + ++requestCount, path, projectID, threadID };
    clearTimeout(expiry);
    expiry = setTimeout(() => { request = null; }, 15000);
    return true;
  }
  function acknowledge(id) {
    if (request?.id !== id) return false;
    request = null;
    clearTimeout(expiry);
    return true;
  }
  function destroy() { request = null; clearTimeout(expiry); }
  return { open, pending: () => request ? JSON.stringify(request) : null, acknowledge, destroy };
})();
