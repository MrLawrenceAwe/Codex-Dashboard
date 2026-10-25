// Private host contracts are resolved by capabilities, never by saved credentials.
async function loadSentMessageDictationHost() {
  const isStreaming = value => typeof value === 'function'
    && ['start', 'finish', 'close', 'transcriptText'].every(name => typeof value.prototype?.[name] === 'function');
  if (location.origin === 'https://chatgpt.com') {
    const runtimePath = window.__reactRouterManifest?.entry?.imports?.[0];
    if (!runtimePath || !runtimePath.startsWith('/cdn/assets/')) throw new Error('ChatGPT runtime is not available in this build.');
    const runtime = await import(new URL(runtimePath, location.origin).href);
    const requireHost = runtime.__webpack_require__;
    if (!requireHost?.m) throw new Error('ChatGPT module loader changed.');
    const entry = Object.entries(requireHost.m).find(([, factory]) => {
      const source = Function.prototype.toString.call(factory);
      return source.includes('Dictation requires an authenticated browser session.') && source.includes('transcript.final');
    });
    if (!entry) throw new Error('Built-in ChatGPT dictation is unavailable in this build.');
    const exports = requireHost(entry[0]);
    const Streaming = Object.values(exports).find(isStreaming);
    if (!Streaming) throw new Error('Built-in dictation contract changed.');
    return { Streaming, host: 'ChatGPT web', contract: entry[0] };
  }
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
  throw new Error('Edit dictation supports ChatGPT web and the Codex desktop renderer.');
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

function hasOtherSentMessageSpeechInput() {
  if (document.querySelector('[data-dictation-view], [data-realtime-voice-orb]')) return true;
  const visited = new Set();
  for (const element of document.querySelectorAll('button')) {
    const key = Object.keys(element).find(name => name.startsWith('__reactFiber$'));
    for (let fiber = key && element[key]; fiber && !visited.has(fiber); fiber = fiber.return) {
      visited.add(fiber);
      const props = fiber.memoizedProps;
      if (props?.isDictating || props?.isDictationStarting || props?.isTranscribing) return true;
      const phase = props?.realtimeSession?.thread?.phase;
      if (typeof phase === 'string' && phase !== 'inactive') return true;
    }
  }
  return false;
}
