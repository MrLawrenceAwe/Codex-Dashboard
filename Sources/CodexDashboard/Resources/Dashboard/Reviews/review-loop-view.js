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
        <label>Previous reviews<select data-review-history-select aria-label="Previous review loop"></select></label>
        <div class="review-history-actions">
          <button type="button" data-review-history-action="delete">Delete selected</button>
          <button type="button" data-review-history-action="deleteOlder" aria-describedby="review-history-delete-help">Delete earlier reviews</button>
          <button type="button" data-review-history-action="deleteAll">Delete all history</button>
        </div>
        <p id="review-history-delete-help" class="review-field-help">Deletes saved reviews before the selected review. Review chats remain available.</p>
        <details class="review-history-details" data-review-history-details>
          <summary>Review details</summary>
          <div data-review-history-card></div>
        </details>
      </section>
      `;
    page.append(details);
    return page;
  }

  function renderNavigationStatus(snapshot) {
    const spinner = document.querySelector('[data-review-navigation-running]');
    if (!spinner) return;
    const runningCount = snapshot.loops.filter(loop => ['waiting', 'running'].includes(loop.phase)).length;
    const label = `${runningCount} running or waiting review ${runningCount === 1 ? 'loop' : 'loops'}`;
    spinner.hidden = runningCount === 0;
    spinner.setAttribute('aria-label', label);
    spinner.setAttribute('title', label);
    spinner.querySelector('[data-review-navigation-running-count]').textContent = String(runningCount);
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
    const options = history.map(loop => `<option value="${escape(loop.id)}">${escape(loop.project.name)} · ${escape(reviewLoopCardView.phaseLabel(loop))} · ${loop.completedRoundCount} of ${loop.maxRounds} rounds</option>`).join('');
    if (historySelect.dataset.options !== options) {
      historySelect.innerHTML = options;
      historySelect.dataset.options = options;
      historySelect.value = history.some(loop => loop.id === selectedID) ? selectedID : history[0]?.id || '';
    }
    const selectedIndex = history.findIndex(loop => loop.id === historySelect.value);
    root.querySelectorAll('[data-review-history-action]').forEach(button => {
      button.disabled = !!pendingAction || (button.dataset.reviewHistoryAction === 'deleteOlder' && selectedIndex >= history.length - 1);
    });
    reviewLoopCardView.renderCards(root.querySelector('[data-review-history-card]'), history.filter(loop => loop.id === historySelect.value), snapshot, pendingAction, new Set(), isFinished);
  }

  return { createPage, render, renderNavigationStatus };
})();
