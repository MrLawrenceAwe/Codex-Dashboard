const reviewLoopPage = (() => {
  let snapshot = { projects: [], loop: null, error: null };
  let pendingAction = null;
  let projectsSignature = '';
  let modelsSignature = '';
  const escape = domUtils.escapeHTML;
  const panel = () => document.querySelector('[data-review-loop]');
  const terminal = loop => !loop || ['completed', 'stopped', 'blocked'].includes(loop.phase);

  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.reviewPage,
    navigationID: dashboardElements.elementIDs.reviewNavButton,
    rootClass: 'codex-review-open',
  });

  function mountNavigation() {
    return mountDashboardNavigationButton({
      id: dashboardElements.elementIDs.reviewNavButton,
      afterID: dashboardElements.elementIDs.todoNavButton,
      label: 'Review loop',
      markup: `<span class="review-nav-icon">${dashboardIcons.render('restore')}</span><span>Review loop</span>`,
    });
  }

  function mount() {
    if (document.getElementById(dashboardElements.elementIDs.reviewPage)) return true;
    const host = codexHost.pageHost();
    if (!host) return false;
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.reviewPage;
    page.setAttribute('aria-label', 'Review loop');
    const details = document.createElement('div');
    details.className = 'dashboard-review-loop';
    details.dataset.reviewLoop = '';
    details.innerHTML = `
      <header><h1>Review loop</h1><span data-review-badge></span></header>
      <p>Each review uses a fresh chat. If it finds issues at your selected priority, a follow-up asks Codex to address them and commit. A review with no qualifying issues stops the loop.</p>
      <form data-review-form>
        <label>Project<select data-review-project required aria-label="Review project"></select></label>
        <label>Priority limit<select data-review-priority aria-label="Review priority limit">
          <option value="P0">P0 — critical</option><option value="P1">P1+ — high</option>
          <option value="P2" selected>P2+ — normal</option><option value="P3">P3+ — all</option>
        </select></label>
        <label>Maximum rounds<input data-review-limit type="number" min="1" max="20" value="5" required></label>
        <label>Model<select data-review-model aria-label="Review model"><option value="">Use Codex defaults</option></select></label>
        <label>Reasoning effort<select data-review-effort aria-label="Review reasoning effort"><option value="">Model default</option></select></label>
        <label class="review-instructions">Review instructions (optional)<textarea data-review-instructions rows="3" maxlength="20000" placeholder="Areas or behavior to focus on"></textarea></label>
        <p class="review-instructions">Runs in the existing checkout using your selected model. Start from a clean branch; keep Codex and Dashboard running. Only local projects with one folder are supported.</p>
        <button type="submit" data-review-start>Start review loop</button>
      </form>
      <div data-review-status role="status" aria-live="polite"></div>
      <div data-review-error role="alert" hidden></div>
      <div class="review-controls" data-review-controls></div>
      <ol data-review-rounds></ol>`;
    page.append(details);
    host.append(page);
    details.querySelector('form').addEventListener('submit', event => {
      event.preventDefault();
      if (!event.target.reportValidity()) return;
      const model = details.querySelector('[data-review-model]').value;
      const effort = details.querySelector('[data-review-effort]').value;
      queue({ selection: model ? { model, effort: effort || null } : null, kind: 'start', projectID: details.querySelector('[data-review-project]').value,
        instructions: details.querySelector('[data-review-instructions]').value,
        priorityLimit: details.querySelector('[data-review-priority]').value,
        maxRounds: Number(details.querySelector('[data-review-limit]').value) });
    });
    details.querySelector('[data-review-model]').addEventListener('change', renderEfforts);
    details.addEventListener('click', event => {
      const control = event.target.closest('[data-review-action]');
      if (control) queue({ kind: control.dataset.reviewAction, loopID: snapshot.loop?.id });
      const thread = event.target.closest('[data-review-thread]');
      if (thread) {
        dashboardNavigation.close();
        codexHost.navigateToThread({ id: thread.dataset.reviewThread });
      }
    });
    projectsSignature = '';
    modelsSignature = '';
    render();
    pageState.applyVisibility();
    return true;
  }

  function queue(action) {
    if (pendingAction) return;
    pendingAction = { ...action, id: crypto.randomUUID() };
    render();
  }

  function renderEfforts() {
    const root = panel();
    if (!root) return;
    const model = (snapshot.models || []).find(item => item.model === root.querySelector('[data-review-model]').value);
    const select = root.querySelector('[data-review-effort]');
    const selected = select.value;
    select.innerHTML = '<option value="">Model default</option>' + (model?.efforts || []).map(value => `<option value="${escape(value)}">${escape(value === 'xhigh' ? 'Extra high' : value.charAt(0).toUpperCase() + value.slice(1))}</option>`).join('');
    if (model?.efforts.includes(selected)) select.value = selected;
    select.disabled = !model || !!pendingAction;
  }

  function render() {
    const root = panel();
    if (!root) return;
    const { loop, projects, error } = snapshot;
    const models = snapshot.models || [];
    const modelSelect = root.querySelector('[data-review-model]');
    const nextModelsSignature = JSON.stringify(models);
    if (nextModelsSignature !== modelsSignature) {
      const selected = modelSelect.value;
      modelSelect.innerHTML = '<option value="">Use Codex defaults</option>' + models.map(model => `<option value="${escape(model.model)}">${escape(model.displayName)}</option>`).join('');
      if (selected) {
        if (!models.some(model => model.model === selected)) modelSelect.add(new Option(`Unavailable · ${selected}`, selected));
        modelSelect.value = selected;
      }
      modelsSignature = nextModelsSignature;
      renderEfforts();
    }
    const select = root.querySelector('[data-review-project]');
    const signature = JSON.stringify(projects);
    if (signature !== projectsSignature) {
      const selected = select.value;
      select.innerHTML = projects.length ? projects.map(project => `<option value="${escape(project.id)}">${escape(project.name)} — ${escape(project.path)}</option>`).join('') : '<option value="">No local projects available</option>';
      if (projects.some(project => project.id === selected)) select.value = selected;
      projectsSignature = signature;
    }
    root.querySelector('[data-review-form]').hidden = !terminal(loop);
    root.querySelectorAll('[data-review-form] input, [data-review-form] textarea, [data-review-form] select, [data-review-start]').forEach(element => { element.disabled = !!pendingAction || !projects.length; });
    root.querySelector('[data-review-effort]').disabled ||= !modelSelect.value;
    root.querySelector('[data-review-badge]').textContent = loop ? `· ${loop.phase}` : '';
    root.querySelector('[data-review-status]').textContent = pendingAction ? 'Saving…' : loop ? `${loop.project.name} · ${loop.selection ? `${loop.selection.model}${loop.selection.effort ? ` / ${loop.selection.effort}` : ''} · ` : ''}${loop.priorityLimit}${loop.priorityLimit === 'P0' ? '' : '+'}: ${loop.message}` : '';
    const notice = root.querySelector('[data-review-error]');
    notice.hidden = !error;
    notice.textContent = error || '';
    const controls = root.querySelector('[data-review-controls]');
    controls.innerHTML = terminal(loop) ? '' : `${loop.phase === 'paused'
      ? '<button type="button" data-review-action="resume">Resume</button>'
      : `<button type="button" data-review-action="pause" ${loop.pauseRequested ? 'disabled' : ''}>${loop.phase === 'running' ? 'Pause after this round' : 'Pause'}</button>`}
      <button type="button" data-review-action="stop">Stop loop</button>`;
    if (pendingAction) controls.querySelectorAll('button').forEach(button => { button.disabled = true; });
    root.querySelector('[data-review-rounds]').innerHTML = (loop?.rounds || []).map(round => `<li>
      ${round.threadID ? `<button type="button" data-review-thread="${escape(round.threadID)}">Review ${round.number}</button>` : `Review ${round.number}`}
      <span>${escape(round.result?.outcome || (round.fixRequested ? 'Addressing findings' : round.review ? `${round.review.findings.filter(finding => finding.priority <= loop.priorityLimit).length} qualifying issues` : 'Reviewing'))}${round.result?.commit ? ` · ${escape(round.result.commit.slice(0, 8))}` : ''}</span>
      ${round.result ? `<p>${escape(round.result.summary)}</p>` : ''}
    </li>`).join('');
  }
  function apply(next) {
    snapshot = next;
    if (next.acknowledgedActionID === pendingAction?.id) pendingAction = null;
    render();
    return true;
  }
  return { mount, mountNavigation, open: pageState.open, close: pageState.close, isOpen: pageState.isOpen, applyVisibility: pageState.applyVisibility, apply, pendingAction: () => pendingAction ? JSON.stringify(pendingAction) : null };
})();
