const reviewLoopPage = (() => {
  let snapshot = { projects: [], loops: [], reviewTypes: [], error: null };
  let pendingAction = null;
  const retainedLoopIDs = new Set();

  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.reviewPage,
    navigationID: dashboardElements.elementIDs.reviewNavButton,
    rootClass: 'codex-review-open',
  });

  function mountNavigation() {
    const mounted = mountDashboardNavigationButton({
      id: dashboardElements.elementIDs.reviewNavButton,
      afterID: dashboardElements.elementIDs.todoNavButton,
      label: 'Review loops',
      markup: `<span class="review-nav-copy"><span class="review-nav-icon">${dashboardIcons.render('restore')}</span><span>Review loops</span></span><span class="review-nav-spinner" data-review-navigation-running role="status" aria-label="0 running or waiting review loops" title="0 running or waiting review loops" hidden><span data-review-navigation-running-count aria-hidden="true">0</span></span>`,
    });
    if (mounted) reviewLoopView.renderNavigationStatus(snapshot);
    return mounted;
  }

  function mountPage() {
    if (document.getElementById(dashboardElements.elementIDs.reviewPage)) return true;
    const host = codexHost.pageHost();
    if (!host) return false;
    const page = reviewLoopView.createPage();
    const details = page.querySelector('[data-review-loop]');
    host.append(page);
    details.querySelector('form').addEventListener('submit', event => {
      event.preventDefault();
      if (!event.target.reportValidity()) return;
      const selection = kind => {
        const model = details.querySelector(`[data-${kind}-model]`).value;
        const effort = details.querySelector(`[data-${kind}-effort]`).value;
        return model ? { modelID: model, reasoningEffort: effort || null } : null;
      };
      const focus = details.querySelector('[data-review-focus]').value;
      queue({ reviewSelection: selection('review'), fixSelection: selection('fix'), kind: 'start', projectID: details.querySelector('[data-review-project]').value,
        focus,
        liveTesting: reviewLoopSetupView.supportsLiveTesting(focus) && details.querySelector('[data-review-live-testing]').value === 'true',
        reloadExtensionBeforeTesting: reviewLoopSetupView.supportsLiveTesting(focus) && details.querySelector('[data-review-live-testing]').value === 'true' && details.querySelector('[data-review-extension]').value === 'true',
        muteMedia: reviewLoopSetupView.supportsLiveTesting(focus) && details.querySelector('[data-review-live-testing]').value === 'true' && details.querySelector('[data-review-mute-media]').value === 'true',
        pushToRemote: details.querySelector('[data-review-push]').value === 'true',
        speed: details.querySelector('[data-review-speed]').value,
        promptContext: { kind: reviewLoopSetupView.supportsProjectContext(focus) ? details.querySelector('[data-review-prompt-context]').value || 'general' : 'general' },
        priorityLimit: reviewLoopSetupView.usesPriorities(focus) ? details.querySelector('[data-review-priority]').value : null,
        maxRounds: Number(details.querySelector('[data-review-limit]').value) });
    });
    details.querySelector('[data-review-live-testing]').addEventListener('change', () => reviewLoopSetupView.renderReviewSettings());
    details.querySelector('[data-review-focus]').addEventListener('change', () => reviewLoopSetupView.renderReviewSettings());
    for (const kind of ['review', 'fix']) {
      const model = details.querySelector(`[data-${kind}-model]`);
      model.addEventListener('change', () => reviewLoopSetupView.renderReasoningOptions(snapshot, pendingAction, kind));
      model.addEventListener('invalid', () => { details.querySelector('.review-execution-options').open = true; });
    }
    details.addEventListener('change', event => {
      const control = event.target.closest('[data-review-loop-mute-media]');
      if (control) queue({ kind: 'setMuteMedia', loopID: control.dataset.reviewLoopId, muteMedia: control.checked });
    });
    details.querySelector('[data-review-history-select]').addEventListener('change', render);
    details.addEventListener('click', event => {
      const historyAction = event.target.closest('[data-review-history-action]');
      if (historyAction) {
        const kind = historyAction.dataset.reviewHistoryAction;
        const loopID = details.querySelector('[data-review-history-select]').value;
        const message = { delete: 'Delete this saved loop?', deleteOlder: 'Delete all saved loops older than this one?', deleteAll: 'Delete all saved previous loops?' }[kind];
        if (message && window.confirm(`${message} Review chats will remain available.`)) queue({ kind, loopID: kind === 'deleteAll' ? null : loopID });
        return;
      }
      const file = event.target.closest('[data-review-file]');
      if (file) {
        queue({ kind: 'openFile', loopID: file.dataset.reviewLoopId, filePath: file.dataset.reviewFile });
        return;
      }
      const control = event.target.closest('[data-review-action]');
      if (control) queue({ kind: control.dataset.reviewAction, loopID: control.dataset.reviewLoopID });
      const clear = event.target.closest('[data-review-clear]');
      if (clear) {
        retainedLoopIDs.delete(clear.dataset.reviewClear);
        render();
        return;
      }
      const thread = event.target.closest('[data-review-thread]');
      if (thread) {
        dashboardNavigation.close();
        codexHost.navigateToThread({ id: thread.dataset.reviewThread });
      }
    });
    reviewLoopSetupView.reset();
    render();
    pageState.applyVisibility();
    return true;
  }

  function queue(action) {
    if (pendingAction) return;
    pendingAction = { ...action, id: crypto.randomUUID() };
    render();
  }

  function render() {
    reviewLoopView.render(snapshot, pendingAction, retainedLoopIDs);
  }

  function apply(next) {
    snapshot = next;
    if (pageState.isOpen()) {
      for (const loop of next.loops) {
        if (!next.finishedLoopIDs?.includes(loop.id)) retainedLoopIDs.add(loop.id);
      }
    }
    const knownIDs = new Set(next.loops.map(loop => loop.id));
    for (const id of retainedLoopIDs) if (!knownIDs.has(id)) retainedLoopIDs.delete(id);
    if (next.acknowledgedActionID === pendingAction?.id) pendingAction = null;
    render();
    return true;
  }
  function open() {
    if (!pageState.open()) return false;
    for (const loop of snapshot.loops) {
      if (!snapshot.finishedLoopIDs?.includes(loop.id)) retainedLoopIDs.add(loop.id);
    }
    render();
    return true;
  }
  function close() {
    if (!pageState.isOpen()) return;
    pageState.close();
    retainedLoopIDs.clear();
    render();
  }
  function destroy() {
    close();
    pendingAction = null;
  }

  return { mountPage, mountNavigation, open, close, destroy, isOpen: pageState.isOpen, applyVisibility: pageState.applyVisibility, apply, pendingAction: () => pendingAction ? JSON.stringify(pendingAction) : null };
})();
