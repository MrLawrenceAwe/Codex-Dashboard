const reviewLoopView = (() => {
  let finishedLoopIDs = new Set();
  const escape = domUtils.escapeHTML;
  const panel = () => document.querySelector('[data-review-loop]');
  const isFinished = loop => finishedLoopIDs.has(loop.id);

  function createPage() {
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.reviewPage;
    page.setAttribute('aria-label', 'Review loops');
    const details = document.createElement('div');
    details.className = 'dashboard-review-loop';
    details.dataset.reviewLoop = '';
    details.innerHTML = `
      <header class="review-page-header">
        <div class="review-title-icon" aria-hidden="true">${dashboardIcons.render('restore')}</div>
        <h1>Review loops</h1><span class="review-overview" data-review-overview></span>
      </header>
      <section class="review-monitor" aria-labelledby="review-active-title">
        <div class="review-region-heading"><h2 id="review-active-title">Current loops</h2><span data-review-active-count class="review-count">0</span></div>
        <section class="review-board" data-review-board aria-label="Current review loops"></section>
        <div class="review-empty" data-review-empty><strong>No current loops</strong></div>
      </section>
      ${reviewLoopSetupView.formMarkup()}
      <section class="review-history" data-review-history aria-labelledby="review-history-title" hidden>
        <div class="review-region-heading"><h2 id="review-history-title">Previous loops</h2><span data-review-history-count class="review-count"></span></div>
        <label>Previous loops<select data-review-history-select aria-label="Previous review loop"></select></label>
        <p class="review-field-help" data-review-history-type></p>
        <p class="review-field-help" data-review-history-updated></p>
        <div class="review-history-actions">
          <button type="button" data-review-history-action="delete">Delete selected</button>
          <button type="button" data-review-history-action="deleteOlder" aria-describedby="review-history-delete-help">Delete earlier loops</button>
          <button type="button" data-review-history-action="deleteAll">Delete all history</button>
        </div>
        <p id="review-history-delete-help" class="review-field-help">Deletes saved loops before the selected loop. Review chats remain available.</p>
        <details class="review-history-details" data-review-history-details>
          <summary>Loop details</summary>
          <div data-review-history-card></div>
        </details>
      </section>
      `;
    page.append(details);
    return page;
  }

  function renderNavigationStatus(snapshot) {
    const statuses = [
      { kind: 'running', phases: ['waiting', 'running'], label: 'running or waiting' },
      { kind: 'blocked', phases: ['blocked', 'awaitingExtensionReload'], label: 'blocked or awaiting extension reload' },
      { kind: 'done', phases: ['completed', 'limitReached'], label: 'done (completed or round limit reached)' },
    ];
    for (const { kind, phases, label } of statuses) {
      const marker = document.querySelector(`[data-review-navigation-${kind}]`);
      if (!marker) continue;
      const count = snapshot.loops.filter(loop => phases.includes(loop.phase)).length;
      const description = `${count} ${label} review ${count === 1 ? 'loop' : 'loops'}`;
      marker.hidden = count === 0;
      marker.setAttribute('aria-label', description);
      marker.setAttribute('title', description);
      marker.querySelector(`[data-review-navigation-${kind}-count]`).textContent = String(count);
    }
  }

  function render(snapshot, pendingAction, retainedLoopIDs = new Set()) {
    finishedLoopIDs = new Set(snapshot.finishedLoopIDs || []);
    renderNavigationStatus(snapshot);
    const root = panel();
    if (!root) return;
    const { loops, error } = snapshot;
    reviewLoopSetupView.render(snapshot, pendingAction, isFinished);
    const activeCount = loops.filter(loop => !isFinished(loop)).length;
    const current = loops.filter(loop => !isFinished(loop) || retainedLoopIDs.has(loop.id));
    root.querySelector('[data-review-empty]').hidden = current.length > 0;
    root.querySelector('[data-review-active-count]').textContent = current.length;
    root.querySelector('[data-review-overview]').textContent = loops.length ? `${activeCount} active · ${loops.length} total` : '';
    const notice = root.querySelector('[data-review-error]');
    notice.hidden = !error;
    notice.textContent = error || '';
    reviewLoopCardView.renderCards(root.querySelector('[data-review-board]'), current, snapshot, pendingAction, retainedLoopIDs, isFinished);
    const history = loops.filter(loop => isFinished(loop) && !retainedLoopIDs.has(loop.id)).reverse();
    root.querySelector('[data-review-history]').hidden = !history.length;
    root.querySelector('[data-review-history-count]').textContent = history.length;
    const historySelect = root.querySelector('[data-review-history-select]');
    const selectedID = historySelect.value;
    const typeLabel = loop => reviewPresentation.focusLabel(loop.focus, snapshot.reviewTypes || []) || 'Not recorded';
    const options = history.map(loop => `<option value="${escape(loop.id)}">${escape(loop.project.name)} · ${escape(typeLabel(loop))} · ${escape(reviewPresentation.updatedAtLabel(loop.updatedAt))}</option>`).join('');
    if (historySelect.dataset.options !== options) {
      historySelect.innerHTML = options;
      historySelect.dataset.options = options;
      historySelect.value = history.some(loop => loop.id === selectedID) ? selectedID : history[0]?.id || '';
    }
    const selectedIndex = history.findIndex(loop => loop.id === historySelect.value);
    root.querySelector('[data-review-history-type]').textContent = selectedIndex < 0 ? ''
      : `Review type: ${typeLabel(history[selectedIndex])}`;
    root.querySelector('[data-review-history-updated]').textContent = selectedIndex < 0 ? ''
      : `Last updated: ${reviewPresentation.updatedAtLabel(history[selectedIndex].updatedAt)}`;
    root.querySelectorAll('[data-review-history-action]').forEach(button => {
      button.disabled = !!pendingAction || (button.dataset.reviewHistoryAction === 'deleteOlder' && selectedIndex >= history.length - 1);
    });
    reviewLoopCardView.renderCards(root.querySelector('[data-review-history-card]'), history.filter(loop => loop.id === historySelect.value), snapshot, pendingAction, new Set(), isFinished);
  }

  return { createPage, render, renderNavigationStatus };
})();
