function createSentMessageDictation({
  loadHost = loadSentMessageDictationHost,
  editorController = sentMessageEditorController,
  hasOtherSpeech = hasOtherSentMessageSpeechInput,
} = {}) {
  const selector = '[contenteditable="true"][role="textbox"][aria-label="Edit message"]';
  const controls = new Map();
  let session = null;
  let observer;
  let frame;
  let guardTimer;
  let destroyed = false;
  let lastResult = { state: 'idle' };
  let cachedHost;

  function viewFor(editor) {
    const view = editorController(editor)?.view;
    if (!view || view.isDestroyed || view.dom !== editor) throw new Error('The edit field does not expose a supported editor.');
    return view;
  }
  function valid(target) {
    return !destroyed && session === target && !target.cancelled && target.editor.isConnected
      && location.href === target.route && !target.view.isDestroyed
      && target.view.state.doc === target.document;
  }
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('width', '20'); svg.setAttribute('height', '20');
    svg.setAttribute('viewBox', '0 0 20 20'); svg.setAttribute('aria-hidden', 'true');
    if (name === 'stop') {
      const square = document.createElementNS(svg.namespaceURI, 'rect');
      for (const [key, value] of Object.entries({ x: 5, y: 5, width: 10, height: 10, rx: 2, fill: 'currentColor' })) square.setAttribute(key, value);
      svg.append(square);
    } else {
      const path = document.createElementNS(svg.namespaceURI, 'path');
      path.setAttribute('d', name === 'cancel' ? 'M6 6l8 8M14 6l-8 8' : 'M10 3a2.5 2.5 0 0 0-2.5 2.5v4a2.5 2.5 0 0 0 5 0v-4A2.5 2.5 0 0 0 10 3ZM5 9.5a5 5 0 0 0 10 0M10 14.5V17M7.5 17h5');
      path.setAttribute('fill', 'none'); path.setAttribute('stroke', 'currentColor');
      path.setAttribute('stroke-width', '1.5'); path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round'); svg.append(path);
    }
    return svg;
  }
  function show(entry, state, message) {
    const active = ['starting', 'recording', 'transcribing'].includes(state);
    const label = state === 'recording' ? 'Stop dictation' : state === 'transcribing' ? 'Transcribing' : 'Dictate';
    entry.row.dataset.editDictationState = state;
    entry.start.replaceChildren(...(state === 'recording' ? [icon('stop')] : entry.microphone.map(node => node.cloneNode(true))));
    entry.start.setAttribute('aria-label', label);
    entry.start.setAttribute('title', label);
    entry.start.setAttribute('aria-pressed', String(state === 'recording'));
    entry.start.setAttribute('aria-busy', String(state === 'starting' || state === 'transcribing'));
    entry.start.disabled = state === 'starting' || state === 'transcribing';
    entry.cancel.hidden = !active;
    entry.cancel.style.setProperty('display', active ? 'inline-flex' : 'none');
    entry.status.className = active || state === 'error' ? 'text-xs text-tertiary' : 'sr-only';
    entry.status.textContent = state === 'starting' ? 'Starting…' : state === 'recording' ? 'Listening…'
      : state === 'transcribing' ? 'Transcribing…' : message;
  }
  function release(target) {
    clearTimeout(target.limit);
    clearTimeout(target.deadline);
    target.stream?.getTracks().forEach(track => track.stop());
    target.audio?.close().catch(() => {});
    target.client?.close();
  }
  function cancel(reason = 'Dictation cancelled.') {
    const target = session;
    if (!target) return;
    session = null;
    target.cancelled = true;
    release(target);
    lastResult = { state: 'cancelled', message: reason };
    show(target.entry, 'idle', reason);
  }
  function fail(target, error) {
    if (session !== target) return;
    session = null;
    target.cancelled = true;
    release(target);
    // Host errors can contain request details. Only display our fixed messages.
    const message = error?.name === 'NotAllowedError' ? 'Microphone access was denied.'
      : error?.message?.startsWith('The edit') ? error.message
      : 'Dictation could not complete. Your message is unchanged. Try again.';
    lastResult = { state: 'error', message, stage: target.state };
    show(target.entry, 'error', message);
  }
  function insert(target, transcript) {
    if (!valid(target)) throw new Error('The edit field changed. Dictation was not inserted.');
    const text = transcript.trim();
    if (!text) return;
    const { from, to } = target.selection;
    const doc = target.view.state.doc;
    const before = doc.textBetween(Math.max(0, from - 1), from, '\n');
    const after = doc.textBetween(to, Math.min(doc.content.size, to + 1), '\n');
    const content = `${before && !/\s$/.test(before) ? ' ' : ''}${text}${after && !/^\s/.test(after) ? ' ' : ''}`;
    const transaction = target.view.state.tr.insertText(content, from, to).scrollIntoView();
    target.view.dispatch(transaction);
    target.view.focus();
  }
  async function stop() {
    const target = session;
    if (!target || target.state !== 'recording') return;
    target.state = 'transcribing';
    clearTimeout(target.limit);
    show(target.entry, 'transcribing', 'Transcribing with the built-in service…');
    target.deadline = setTimeout(() => cancel('Transcription timed out. Your message is unchanged.'), 65000);
    try {
      const transcript = await target.client.finish();
      if (session !== target) return;
      insert(target, transcript);
      session = null;
      release(target);
      lastResult = { state: 'inserted', characters: transcript.length, fixture: target.fixture };
      show(target.entry, 'idle', transcript.trim() ? 'Inserted. Review before sending.' : 'No speech detected.');
    } catch (error) { fail(target, error); }
  }
  async function start(editor, fixture) {
    if (session) throw new Error('Another edit dictation is active.');
    if (hasOtherSpeech()) throw new Error('Stop the existing voice or dictation session first.');
    const view = viewFor(editor);
    const entry = controls.get(editor);
    if (!entry) throw new Error('The edit field is not mounted.');
    const target = { editor, view, entry, route: location.href, document: view.state.doc,
      selection: { from: view.state.selection.from, to: view.state.selection.to }, state: 'starting', fixture: Boolean(fixture) };
    session = target;
    show(entry, 'starting', 'Starting built-in dictation…');
    lastResult = { state: 'starting', fixture: target.fixture };
    try {
      cachedHost ||= await loadHost();
      if (!valid(target)) { if (session === target) cancel('The edit field changed.'); return; }
      target.client = new cachedHost.Streaming('composer', undefined, undefined, {
        onError: () => fail(target, new Error('Stream failed')),
        onStopRequested: () => { void stop(); },
      });
      // Use final-only mode, avoiding partial text mutations in either editor.
      if (fixture) {
        target.audio = new AudioContext();
        const bytes = Uint8Array.from(atob(fixture), character => character.charCodeAt(0));
        const buffer = await target.audio.decodeAudioData(bytes.buffer);
        if (!valid(target)) { release(target); return; }
        const source = target.audio.createBufferSource();
        source.buffer = buffer;
        const destination = target.audio.createMediaStreamDestination();
        source.connect(destination); // No connection to speakers; synthetic audio stays private.
        target.stream = destination.stream;
        await target.audio.resume();
        await target.client.start(target.stream);
        if (!valid(target)) { release(target); return; }
        target.state = 'recording';
        source.onended = () => {
          if (session === target && !target.cancelled) target.limit = setTimeout(() => {
            if (session === target) void stop();
          }, 700);
        };
        source.start();
      } else {
        target.stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1 } });
        if (!valid(target)) { release(target); return; }
        await target.client.start(target.stream);
        if (!valid(target)) { release(target); return; }
        target.state = 'recording';
        target.limit = setTimeout(() => { void stop(); }, 120000);
      }
      show(entry, 'recording', fixture ? 'Testing the built-in service with bundled speech…' : 'Recording. Click Stop dictation when finished.');
      lastResult = { state: 'recording', fixture: target.fixture };
    } catch (error) { fail(target, error); }
  }
  function add(editor) {
    const form = editor.closest('form');
    if (!form || controls.has(editor)) return;
    const row = document.createElement('div');
    row.dataset.editDictationControls = '';
    row.className = 'flex items-center gap-1.5';
    const submit = form.querySelector('button[type="submit"]');
    const footer = submit?.parentElement;
    const reference = [...form.querySelectorAll('button')].find(button => button.type !== 'submit'
      && !button.closest('[data-edit-dictation-controls]')) || submit;
    const nativeMicrophone = [...document.querySelectorAll('button[aria-label="Dictate"]')]
      .find(button => !button.closest('[data-edit-dictation-controls]'));
    const height = reference ? getComputedStyle(reference).height : '32px';
    const button = label => {
      const element = document.createElement('button');
      element.type = 'button';
      element.className = nativeMicrophone?.className || reference?.className || '';
      element.setAttribute('aria-label', label); element.setAttribute('title', label);
      element.style.cssText = `display:inline-flex;align-items:center;justify-content:center;flex:none;width:${height};height:${height};min-width:${height};padding:0;border-color:transparent;border-radius:50%`;
      return element;
    };
    const microphone = nativeMicrophone ? [...nativeMicrophone.childNodes].map(node => node.cloneNode(true)) : [icon('microphone')];
    const entry = { row, microphone, start: button('Dictate'), cancel: button('Cancel dictation'), status: document.createElement('span') };
    entry.cancel.replaceChildren(icon('cancel'));
    // A native flex class can override the browser's hidden style.
    entry.cancel.style.setProperty('display', 'none');
    entry.cancel.hidden = true;
    entry.status.setAttribute('role', 'status'); entry.status.setAttribute('aria-live', 'polite');
    entry.status.setAttribute('aria-atomic', 'true');
    entry.start.addEventListener('pointerdown', event => event.preventDefault());
    entry.start.addEventListener('click', event => {
      if (!event.isTrusted) return;
      if (session?.editor === editor) { void stop(); return; }
      void start(editor).catch(() => show(entry, 'error', 'Finish other dictation first, then retry.'));
    });
    entry.cancel.addEventListener('click', () => cancel());
    row.append(entry.status, entry.cancel, entry.start);
    if (footer && footer !== form && !footer.contains(editor)) footer.prepend(row);
    else form.append(row);
    controls.set(editor, entry);
    show(entry, 'idle', '');
  }
  function sync() {
    frame = undefined;
    if (destroyed) return;
    if (session && !valid(session)) cancel('Editing changed. Dictation cancelled.');
    for (const [editor, entry] of controls) {
      if (!editor.isConnected || !editor.closest('form')?.contains(entry.row)) {
        entry.row.remove(); controls.delete(editor);
      }
    }
    for (const editor of document.querySelectorAll(selector)) {
      if (editor.getClientRects().length) add(editor);
    }
  }
  function schedule() { if (frame === undefined) frame = requestAnimationFrame(sync); }
  function handleClick(event) {
    if (!session || event.target.closest?.('[data-edit-dictation-controls]')) return;
    // Stop before native Cancel/Send or navigation is processed.
    if (event.target.closest?.('button, a, [role="menuitem"]')) cancel('Dictation cancelled before leaving the edit field.');
  }
  function routeChanged() { cancel('Navigation cancelled dictation.'); schedule(); }
  return {
    mount() {
      if (observer || destroyed) return;
      observer = new MutationObserver(schedule);
      observer.observe(document.body, { childList: true, subtree: true });
      document.addEventListener('click', handleClick, true);
      window.addEventListener('popstate', routeChanged);
      window.addEventListener('pagehide', routeChanged);
      guardTimer = setInterval(() => {
        if (session && (!valid(session) || hasOtherSpeech())) cancel('The active editor or voice session changed.');
      }, 250);
      sync();
    },
    destroy() {
      cancel(); destroyed = true; observer?.disconnect(); clearInterval(guardTimer);
      if (frame !== undefined) cancelAnimationFrame(frame);
      document.removeEventListener('click', handleClick, true);
      window.removeEventListener('popstate', routeChanged);
      window.removeEventListener('pagehide', routeChanged);
      for (const entry of controls.values()) entry.row.remove();
      controls.clear();
    },
    status: () => ({ ...lastResult, active: Boolean(session), editors: controls.size, host: cachedHost?.host }),
    async probe() {
      const host = await loadHost();
      const editor = [...controls.keys()][0];
      return { host: host.host, contract: host.contract, editors: controls.size, supportedEditor: Boolean(editor && editorController(editor)) };
    },
    async runFixture(base64) {
      const editor = [...controls.keys()].find(element => element.getClientRects().length);
      if (!editor) throw new Error('Open a sent message with the pencil/Edit button first.');
      await start(editor, base64);
      return this.status();
    },
    cancel,
  };
}
