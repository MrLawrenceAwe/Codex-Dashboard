const reviewLoopView = (() => {
  let projectsSignature = '';
  let modelsSignature = '';
  const escape = domUtils.escapeHTML;
  const panel = () => document.querySelector('[data-review-loop]');
  const canStartLoop = loop => !loop || ['completed', 'limitReached', 'stopped', 'blocked'].includes(loop.phase);

  function createPage() {
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.reviewPage;
    page.setAttribute('aria-label', 'Review loop');
    const details = document.createElement('div');
    details.className = 'dashboard-review-loop';
    details.dataset.reviewLoop = '';
    details.innerHTML = `
      <header class="review-page-header">
        <div class="review-title-icon" aria-hidden="true">${dashboardIcons.render('restore')}</div>
        <div><h1>Review loop</h1><p>Review, fix, and verify in fresh tasks until no qualifying issues remain.</p></div>
      </header>
      <form data-review-form>
        <div class="review-setup-heading"><h2>Configure your loop</h2></div>
        <fieldset class="review-scope"><legend>Review scope</legend>
        <label class="review-project">Project<select data-review-project required aria-label="Review project"></select></label>
        <label>Project type<select data-review-project-type aria-label="Project type">
          <option value="">General project</option><option value="personal">Personal project</option>
        </select></label>
        <label>Review and fix priorities<select data-review-priority aria-label="Review and fix priority limit">
          <option value="P0">P0 only · Critical</option><option value="P1">P0–P1 · High and critical</option>
          <option value="P2" selected>P0–P2 · Medium and higher</option><option value="P3">P0–P3 · All priorities</option>
        </select></label>
        <label>Max rounds<input data-review-limit type="number" min="1" max="20" value="5" required></label>
        </fieldset>
        <details class="review-execution-options"><summary>Model &amp; speed <span>Optional</span></summary>
        <fieldset class="review-execution"><legend class="review-execution-legend">Execution settings</legend>
        <label>Model<select data-review-model aria-label="Review model"><option value="">Codex default</option></select></label>
        <label>Reasoning<select data-review-effort aria-label="Review reasoning effort"><option value="">Model default</option></select></label>
        <label>Speed<select data-review-speed aria-label="Review speed"><option value="standard" selected>Standard</option><option value="fast">Fast</option></select></label>
        </fieldset>
        </details>
        <div class="review-form-footer">
          <button type="submit" data-review-start>Start loop <span aria-hidden="true">→</span></button>
        </div>
      </form>
      <div data-review-error role="alert" hidden></div>
      <section class="review-activity" data-review-activity aria-labelledby="review-activity-title">
        <div class="review-section-heading"><h2 id="review-activity-title">Loop status</h2><span data-review-badge hidden></span></div>
        <div data-review-context class="review-context" hidden></div>
        <div data-review-status role="status" aria-live="polite"></div>
        <div class="review-round-progress" data-review-round-progress hidden><div><span>Rounds completed</span><span data-review-round-count></span></div><progress data-review-meter aria-label="Completed review rounds" value="0" max="5"></progress></div>
        <div class="review-controls" data-review-controls></div>
        <div class="review-live" data-review-live hidden>
          <div class="review-live-heading"><strong data-review-step></strong><button type="button" data-review-current-task hidden>Open task ↗</button></div>
          <details class="review-prompt" data-review-current-prompt>
            <summary><span data-review-current-label>Current prompt</span><span data-review-current-title></span></summary>
            <p data-review-current-note></p><pre data-review-current-text></pre>
          </details>
          <details class="review-prompt" data-review-upcoming-prompt>
            <summary><span>Up next</span><span data-review-upcoming-title></span></summary>
            <p data-review-upcoming-note></p><pre data-review-upcoming-text></pre>
          </details>
          <p class="review-next-message" data-review-next-message></p>
        </div>
        <div class="review-empty" data-review-empty><strong>Ready when you are</strong><p>Each round reviews your project, fixes qualifying findings, and verifies the commit before continuing.</p><div class="review-workflow" aria-label="Round workflow"><span>1 · Review</span><span>2 · Fix &amp; commit</span><span>3 · Verify</span></div></div>
        <ol data-review-rounds aria-label="Review rounds"></ol>
      </section>`;
    page.append(details);
    return page;
  }

  function renderNavigationStatus(snapshot) {
    const spinner = document.querySelector('[data-review-navigation-running]');
    if (spinner) spinner.hidden = !['waiting', 'running'].includes(snapshot.loop?.phase);
  }

  function renderEfforts(snapshot, pendingAction) {
    const root = panel();
    if (!root) return;
    const model = (snapshot.models || []).find(item => item.modelID === root.querySelector('[data-review-model]').value);
    const select = root.querySelector('[data-review-effort]');
    const selected = select.value;
    select.innerHTML = '<option value="">Model default</option>' + (model?.supportedReasoningEfforts || []).map(value => `<option value="${escape(value)}">${escape(value === 'xhigh' ? 'Extra high' : value.charAt(0).toUpperCase() + value.slice(1))}</option>`).join('');
    if (model?.supportedReasoningEfforts.includes(selected)) select.value = selected;
    select.disabled = !model || !!pendingAction;
  }

  function render(snapshot, pendingAction) {
    renderNavigationStatus(snapshot);
    const root = panel();
    if (!root) return;
    const { loop, projects, error } = snapshot;
    const models = snapshot.models || [];
    const modelSelect = root.querySelector('[data-review-model]');
    const nextModelsSignature = JSON.stringify(models);
    if (nextModelsSignature !== modelsSignature) {
      const selected = modelSelect.value;
      modelSelect.innerHTML = '<option value="">Codex default</option>' + models.map(model => `<option value="${escape(model.modelID)}">${escape(model.displayName)}</option>`).join('');
      if (selected) {
        if (!models.some(model => model.modelID === selected)) modelSelect.add(new Option(`Unavailable · ${selected}`, selected));
        modelSelect.value = selected;
      }
      modelsSignature = nextModelsSignature;
      renderEfforts(snapshot, pendingAction);
    }
    const select = root.querySelector('[data-review-project]');
    const signature = JSON.stringify(projects);
    if (signature !== projectsSignature) {
      const selected = select.value;
      select.innerHTML = projects.length ? projects.map(project => `<option value="${escape(project.id)}">${escape(project.name)}</option>`).join('') : '<option value="">No local projects available</option>';
      if (projects.some(project => project.id === selected)) select.value = selected;
      projectsSignature = signature;
    }
    root.querySelector('[data-review-form]').hidden = !canStartLoop(loop);
    const form = root.querySelector('[data-review-form]');
    const activity = root.querySelector('[data-review-activity]');
    if (loop && activity.compareDocumentPosition(form) & Node.DOCUMENT_POSITION_PRECEDING) root.insertBefore(activity, form);
    if (!loop && form.compareDocumentPosition(activity) & Node.DOCUMENT_POSITION_PRECEDING) root.insertBefore(form, activity);
    root.dataset.hasLoop = String(!!loop);
    root.querySelectorAll('[data-review-form] input, [data-review-form] select, [data-review-start]').forEach(element => { element.disabled = !!pendingAction || !projects.length; });
    root.querySelector('[data-review-effort]').disabled ||= !modelSelect.value;
    const badge = root.querySelector('[data-review-badge]');
    badge.textContent = loop?.phase === 'limitReached' ? 'Limit reached' : loop ? loop.phase.charAt(0).toUpperCase() + loop.phase.slice(1) : '';
    badge.hidden = !loop;
    badge.dataset.phase = loop?.phase || '';
    const context = root.querySelector('[data-review-context]');
    context.hidden = !loop;
    context.innerHTML = loop ? `<strong>${escape(loop.project.name)}</strong><span>${loop.priorityLimit === 'P0' ? 'P0' : `P0–${escape(loop.priorityLimit)}`} priorities</span><span>${loop.rounds.length} / ${loop.maxRounds} rounds</span><span>${loop.speed === 'fast' ? 'Fast' : 'Standard'} speed</span>${loop.selection ? `<span>${escape(loop.selection.modelID)}${loop.selection.reasoningEffort ? ` · ${escape(loop.selection.reasoningEffort)}` : ''}</span>` : ''}` : '';
    root.querySelector('[data-review-status]').textContent = pendingAction
      ? ({ start: 'Starting loop…', pause: 'Requesting pause…', resume: 'Resuming loop…', stop: 'Stopping loop…' }[pendingAction.kind] || 'Saving…')
      : loop?.message || '';
    const completedRounds = (loop?.rounds || []).filter(round => round.result).length;
    root.querySelector('[data-review-round-progress]').hidden = !loop;
    root.querySelector('[data-review-round-count]').textContent = loop ? `${completedRounds} of ${loop.maxRounds}` : '';
    const meter = root.querySelector('[data-review-meter]');
    meter.max = loop?.maxRounds || 1;
    meter.value = completedRounds;
    root.querySelector('[data-review-empty]').hidden = !!loop || !!pendingAction;
    renderProgress(root, loop, snapshot.progress);
    root.querySelector('[data-review-start]').innerHTML = pendingAction?.kind === 'start' ? 'Starting…' : `${loop ? 'Start new loop' : 'Start loop'} <span aria-hidden="true">→</span>`;
    const notice = root.querySelector('[data-review-error]');
    notice.hidden = !error;
    notice.textContent = error || '';
    const controls = root.querySelector('[data-review-controls]');
    controls.innerHTML = canStartLoop(loop) ? '' : `${loop.phase === 'paused'
      ? '<button type="button" data-review-action="resume">Resume</button>'
      : `<button type="button" data-review-action="pause" ${loop.pauseRequested ? 'disabled' : ''}>${loop.pauseRequested ? 'Pausing after round…' : loop.phase === 'running' ? 'Pause after round' : 'Pause'}</button>`}
      <button type="button" data-review-action="stop">Stop loop</button>`;
    if (pendingAction) controls.querySelectorAll('button').forEach(button => { button.disabled = true; });
    const expandedRounds = new Set(root.dataset.renderedLoop === loop?.id ? [...root.querySelectorAll('[data-review-rounds] details[open]')].map(details => details.dataset.round) : []);
    root.dataset.renderedLoop = loop?.id || '';
    root.querySelector('[data-review-rounds]').innerHTML = (loop?.rounds || []).map(round => `<li>
      <div class="review-round-number" aria-hidden="true">${round.number}</div><div class="review-round-body"><div class="review-round-heading">
      ${round.threadID ? `<button type="button" data-review-thread="${escape(round.threadID)}">Review ${round.number}</button>` : `Review ${round.number}`}
      <span>${escape(({ clean: 'No qualifying findings', fixed: 'Fixes committed', blocked: 'Blocked' }[round.result?.outcome]) || (round.fixRequested ? 'Addressing findings' : round.review ? `${round.review.findings.filter(finding => finding.priority <= loop.priorityLimit).length} qualifying issues` : 'Reviewing'))}${round.result?.commit ? ` · ${escape(round.result.commit.slice(0, 8))}` : ''}</span></div>
      ${round.result?.summary ? `<details class="review-round-details" data-round="${round.number}" ${expandedRounds.has(String(round.number)) ? 'open' : ''}><summary>View summary</summary><p>${escape(round.result.summary)}</p></details>` : ''}
    </div></li>`).join('');
  }
  function renderProgress(root, loop, progress) {
    const live = root.querySelector('[data-review-live]');
    live.hidden = !loop || !progress;
    if (live.hidden) return;
    if (live.dataset.loopID !== loop.id) {
      live.querySelectorAll('details').forEach(details => { details.open = false; });
      live.dataset.loopID = loop.id;
    }
    root.querySelector('[data-review-step]').textContent = progress.step;
    root.querySelector('[data-review-current-label]').textContent = progress.currentLabel;
    const task = root.querySelector('[data-review-current-task]');
    task.hidden = !progress.threadID;
    if (progress.threadID) task.dataset.reviewThread = progress.threadID;
    else delete task.dataset.reviewThread;
    for (const kind of ['current', 'upcoming']) {
      const prompt = progress[kind];
      root.querySelector(`[data-review-${kind}-prompt]`).hidden = !prompt;
      root.querySelector(`[data-review-${kind}-title]`).textContent = prompt?.title || '';
      root.querySelector(`[data-review-${kind}-text]`).textContent = prompt?.text || '';
      const note = root.querySelector(`[data-review-${kind}-note]`);
      note.textContent = prompt?.note || '';
      note.hidden = !prompt?.note;
    }
    const nextMessage = root.querySelector('[data-review-next-message]');
    nextMessage.hidden = !!progress.upcoming;
    nextMessage.textContent = progress.nextMessage;
  }
  function reset() {
    projectsSignature = '';
    modelsSignature = '';
  }

  return { createPage, render, renderEfforts, renderNavigationStatus, reset };
})();
