const reviewHost = (() => {
  const pending = new Map();
  const methods = new Set(['model/list', 'project/list', 'thread/start', 'thread/name/set', 'turn/start', 'thread/read', 'thread/turns/list', 'thread/items/list']);
  function receive(event) {
    const message = event.data;
    if (message?.type !== 'mcp-response' || message.hostId !== 'local') return;
    const entry = pending.get(message.message?.id);
    if (entry) entry.finish(message.message);
  }
  window.addEventListener('message', receive);
  function request({ method, params }) {
    if (!methods.has(method) || typeof window.electronBridge?.sendMessageFromView !== 'function') {
      return Promise.resolve(JSON.stringify({ error: { message: 'The Codex review connection is unavailable.' } }));
    }
    const id = `dashboard-review-${crypto.randomUUID()}`;
    return new Promise((resolve) => {
      const finish = (message) => {
        if (!pending.has(id)) return;
        clearTimeout(pending.get(id).timer);
        pending.delete(id);
        resolve(JSON.stringify(message));
      };
      const fail = (error) => finish({ error: { message: String(error?.message || error) } });
      const timer = setTimeout(() => fail('Codex did not acknowledge the request. Inspect the review task before retrying.'), 20000);
      pending.set(id, { finish, timer });
      Promise.resolve().then(() => window.electronBridge.sendMessageFromView({
        type: 'mcp-request', hostId: 'local', request: { id, method, params },
      })).catch(fail);
    });
  }
  function destroy() {
    window.removeEventListener('message', receive);
    [...pending.values()].forEach(entry => entry.finish({ error: { message: 'Dashboard disconnected. The request will not be repeated automatically.' } }));
  }
  return { request, destroy };
})();
