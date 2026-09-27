const reviewLoopPage = (() => {
  let snapshot = { projects: [], loops: [], error: null };
  let pendingAction = null;

  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.reviewPage,
    navigationID: dashboardElements.elementIDs.reviewNavButton,
    rootClass: 'codex-review-open',
  });

  function mountNavigation() {
    const mounted = mountDashboardNavigationButton({
      id: dashboardElements.elementIDs.reviewNavButton,
      afterID: dashboardElements.elementIDs.todoNavButton,
      label: 'Review loop',
      markup: `<span class="review-nav-copy"><span class="review-nav-icon">${dashboardIcons.render('restore')}</span><span>Review loop</span></span><span class="review-nav-spinner" data-review-navigation-running role="status" aria-label="Review loop running" title="Review loop running" hidden></span>`,
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
      const model = details.querySelector('[data-review-model]').value;
      const effort = details.querySelector('[data-review-effort]').value;
      queue({ selection: model ? { modelID: model, reasoningEffort: effort || null } : null, kind: 'start', projectID: details.querySelector('[data-review-project]').value,
        speed: details.querySelector('[data-review-speed]').value,
        instructions: details.querySelector('[data-review-project-type]').value === 'personal' ? '(this is a project for personal use)' : '',
        priorityLimit: details.querySelector('[data-review-priority]').value,
        maxRounds: Number(details.querySelector('[data-review-limit]').value) });
    });
    details.querySelector('[data-review-model]').addEventListener('change', () => reviewLoopView.renderEfforts(snapshot, pendingAction));
    details.querySelector('[data-review-history-select]').addEventListener('change', render);
    details.addEventListener('click', event => {
      const control = event.target.closest('[data-review-action]');
      if (control) queue({ kind: control.dataset.reviewAction, loopID: control.dataset.reviewLoopID });
      const thread = event.target.closest('[data-review-thread]');
      if (thread) {
        dashboardNavigation.close();
        codexHost.navigateToThread({ id: thread.dataset.reviewThread });
      }
    });
    reviewLoopView.reset();
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
    reviewLoopView.render(snapshot, pendingAction);
  }

  function apply(next) {
    snapshot = next;
    if (next.acknowledgedActionID === pendingAction?.id) pendingAction = null;
    render();
    return true;
  }
  function destroy() {
    pageState.close();
    pendingAction = null;
  }

  return { mountPage, mountNavigation, open: pageState.open, close: pageState.close, destroy, isOpen: pageState.isOpen, applyVisibility: pageState.applyVisibility, apply, pendingAction: () => pendingAction ? JSON.stringify(pendingAction) : null };
})();
