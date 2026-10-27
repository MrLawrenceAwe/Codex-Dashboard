// Private host contracts are resolved by capabilities, never by saved credentials.
async function loadSentMessageDictationHost() {
  const isStreaming = value => typeof value === 'function'
    && ['start', 'finish', 'close', 'transcriptText'].every(name => typeof value.prototype?.[name] === 'function');
  if (location.protocol === 'app:') {
    let url = performance.getEntriesByType('resource').map(entry => entry.name)
      .find(name => /\/app-initial-[\w-]+\.js(?:\?|$)/.test(name));
    if (!url) {
      const entry = [...document.querySelectorAll('script[type="module"][src]')][0]?.src;
      if (entry) {
        const source = await (await fetch(entry)).text();
        const path = source.match(/["'](\.\/app-initial-[\w-]+\.js)["']/)?.[1];
        if (path) url = new URL(path, entry).href;
      }
    }
    if (!url || new URL(url).origin !== location.origin) throw new Error('Desktop dictation module could not be located.');
    const exports = await import(url);
    const Streaming = Object.values(exports).find(isStreaming);
    if (!Streaming) throw new Error('Desktop dictation contract changed or is not initialized.');
    return { Streaming, host: 'Codex desktop', contract: new URL(url).pathname.split('/').pop() };
  }
  throw new Error('Edit dictation requires the Codex desktop renderer.');
}

function sentMessageEditorController(element) {
  const visited = new Set();
  for (let node = element; node && node !== document.body; node = node.parentElement) {
    const key = Object.keys(node).find(name => name.startsWith('__reactFiber$'));
    for (let fiber = key && node[key]; fiber && !visited.has(fiber); fiber = fiber.return) {
      visited.add(fiber);
      const controller = fiber.memoizedProps?.composerController;
      if (controller?.view?.dom === element && typeof controller.view.state?.tr?.insertText === 'function') return controller;
    }
  }
  return null;
}
