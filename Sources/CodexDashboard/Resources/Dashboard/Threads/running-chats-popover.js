function createRunningChatsPopover({ currentThreads, onOpenThread }) {
  const panelID = 'codex-dashboard-running-chats';
  let trigger;
  let panel;
  let listeners;
  let showTimer;
  let hideTimer;
  let rows = new Map();

  function close() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    if (panel) panel.hidden = true;
    trigger?.setAttribute('aria-expanded', 'false');
    rows.clear();
    panel?.querySelector('[data-running-list]').replaceChildren();
  }

  function position() {
    if (!panel || panel.hidden || !trigger?.isConnected) return;
    const rect = trigger.getBoundingClientRect();
    const width = panel.offsetWidth;
    const left = rect.right + 8 + width <= window.innerWidth
      ? rect.right + 8 : Math.max(8, rect.left - width - 8);
    panel.style.left = `${left}px`;
    panel.style.top = `${Math.max(8, Math.min(rect.top, window.innerHeight - panel.offsetHeight - 8))}px`;
  }

  function update() {
    const threads = currentThreads();
    const running = threads.filter(thread => thread.runState === 'running');
    if (trigger) {
      if (running.length || (panel && !panel.hidden)) {
        trigger.setAttribute('aria-controls', panelID);
        trigger.setAttribute('aria-expanded', String(Boolean(panel && !panel.hidden)));
      } else {
        trigger.removeAttribute('aria-controls');
        trigger.removeAttribute('aria-expanded');
      }
    }
    if (!panel || panel.hidden) return;
    const byID = new Map(threads.map(thread => [thread.id, thread]));
    // Keep chats that finish during this hover session until the popup closes.
    rows.forEach((row, id) => {
      const thread = byID.get(id);
      if (!thread) {
        row.remove();
        rows.delete(id);
      }
    });
    for (const thread of [...running, ...threads.filter(thread => rows.has(thread.id) && thread.runState !== 'running')]) {
      let row = rows.get(thread.id);
      if (!row) {
        row = document.createElement('button');
        row.type = 'button';
        row.dataset.openThread = thread.id;
        row.innerHTML = '<span class="dashboard-running-status"></span><span class="dashboard-running-copy"><span class="dashboard-running-title"></span><span class="dashboard-running-project"></span></span>';
        rows.set(thread.id, row);
        panel.querySelector('[data-running-list]').append(row);
      }
      const isRunning = thread.runState === 'running';
      const usageLimited = thread.latestLifecycleEventKind === 'usageLimitReached';
      const interrupted = !isRunning && (usageLimited || thread.latestLifecycleEventKind === 'aborted');
      const label = isRunning ? 'Running' : interrupted
        ? (usageLimited ? 'Interrupted because the usage limit was reached' : 'Interrupted') : 'Finished';
      row.dataset.running = String(isRunning);
      row.setAttribute('aria-label', `Open chat: ${thread.title}. ${label}`);
      row.querySelector('.dashboard-running-title').textContent = thread.title;
      row.querySelector('.dashboard-running-project').textContent = interrupted
        ? `${thread.projectName} · ${usageLimited ? 'Usage limit reached' : 'Interrupted'}` : thread.projectName;
      const status = row.querySelector('.dashboard-running-status');
      const state = isRunning ? 'running' : interrupted ? 'interrupted' : 'finished';
      if (status.dataset.state !== state) {
        status.dataset.state = state;
        status.innerHTML = isRunning ? '' : dashboardIcons.render(interrupted ? 'usageLimitReached' : 'completed');
      }
      status.setAttribute('aria-label', label);
      status.setAttribute('title', label);
    }
    panel.querySelector('[data-running-heading]').textContent = `Chats · ${rows.size}`;
    if (!rows.size) close();
    else position();
  }

  function show() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    if (!trigger?.isConnected || !currentThreads().some(thread => thread.runState === 'running')) return;
    panel.hidden = false;
    update();
  }

  function scheduleClose() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    hideTimer = window.setTimeout(() => {
      if (panel?.contains(document.activeElement)) return;
      close();
    }, 180);
  }

  function mount(nextTrigger) {
    if (trigger === nextTrigger) return;
    destroy();
    trigger = nextTrigger;
    listeners = new AbortController();
    const options = { signal: listeners.signal };
    panel = document.createElement('section');
    panel.id = panelID;
    panel.hidden = true;
    panel.setAttribute('aria-label', 'Running chats');
    panel.innerHTML = '<div class="dashboard-running-heading" data-running-heading></div><div data-running-list></div>';
    document.body.append(panel);
    trigger.addEventListener('pointerenter', () => {
      clearTimeout(hideTimer);
      clearTimeout(showTimer);
      showTimer = window.setTimeout(show, 180);
    }, options);
    trigger.addEventListener('pointerleave', scheduleClose, options);
    trigger.addEventListener('focus', show, options);
    trigger.addEventListener('blur', scheduleClose, options);
    trigger.addEventListener('click', close, options);
    trigger.addEventListener('keydown', event => {
      if (event.key !== 'ArrowDown') return;
      show();
      if (panel.hidden) return;
      event.preventDefault();
      panel.querySelector('button')?.focus();
    }, options);
    panel.addEventListener('pointerenter', () => clearTimeout(hideTimer), options);
    panel.addEventListener('pointerleave', scheduleClose, options);
    panel.addEventListener('focusin', () => clearTimeout(hideTimer), options);
    panel.addEventListener('focusout', scheduleClose, options);
    panel.addEventListener('click', event => {
      const row = event.target.closest('[data-open-thread]');
      const thread = row && currentThreads().find(thread => thread.id === row.dataset.openThread);
      if (thread) {
        close();
        onOpenThread(thread);
      }
    }, options);
    document.addEventListener('keydown', event => {
      if (event.key !== 'Escape' || panel.hidden) return;
      const restoreFocus = panel.contains(document.activeElement);
      if (restoreFocus) trigger.focus();
      close();
    }, options);
    document.addEventListener('pointerdown', event => {
      if (!trigger.contains(event.target) && !panel.contains(event.target)) close();
    }, options);
    window.addEventListener('resize', close, options);
    document.addEventListener('scroll', event => {
      if (!panel.contains(event.target)) close();
    }, { ...options, capture: true });
    update();
  }

  function destroy() {
    close();
    listeners?.abort();
    panel?.remove();
    trigger?.removeAttribute('aria-controls');
    trigger?.removeAttribute('aria-expanded');
    trigger = undefined;
    panel = undefined;
  }

  return { mount, update, close, destroy };
}
