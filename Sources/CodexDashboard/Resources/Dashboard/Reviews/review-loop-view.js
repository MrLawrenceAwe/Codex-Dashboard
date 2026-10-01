const reviewLoopView = (() => {
  let projectsSignature = '';
  let modelsSignature = '';
  let reviewTypesSignature = '';
  let reviewTypes = [];
  let finishedLoopIDs = new Set();
  const escape = domUtils.escapeHTML;
  const panel = () => document.querySelector('[data-review-loop]');
  const isFinished = loop => finishedLoopIDs.has(loop.id);
  const usesPriorities = focus => reviewTypes.find(type => type.id === focus)?.usesPriorities === true;
  const supportsProjectContext = focus => reviewTypes.find(type => type.id === focus)?.supportsProjectContext === true;
  const reasoningLabel = value => value === 'xhigh' ? 'Extra high' : value.charAt(0).toUpperCase() + value.slice(1);

  function findingBody(body, loopID) {
    const text = String(body || '');
    const links = /\[([^\]\n]+)\]\((<[^>\n]+>|[^)\n]+)\)/g;
    let markup = '';
    let offset = 0;
    for (const match of text.matchAll(links)) {
      markup += escape(text.slice(offset, match.index));
      const label = escape(match[1]);
      const target = match[2].replace(/^<|>$/g, '').trim();
      if (/^https?:\/\//i.test(target)) {
        markup += `<a href="${escape(target)}" target="_blank" rel="noopener noreferrer">${label}</a>`;
      } else if (!/^[a-z][a-z\d+.-]*:/i.test(target) || /:\d+(?::\d+)?$/.test(target) || target.startsWith('file://')) {
        markup += `<button type="button" class="review-file-link" data-review-file="${escape(target)}" data-review-loop-id="${escape(loopID)}">${label}</button>`;
      } else {
        markup += escape(match[0]);
      }
      offset = match.index + match[0].length;
    }
    return markup + escape(text.slice(offset));
  }

  function renderReviewSettings() {
    const root = panel();
    if (!root) return;
    const focus = root.querySelector('[data-review-focus]').value;
    root.querySelector('.review-priority').hidden = !usesPriorities(focus);
    const context = root.querySelector('.review-project-context');
    context.hidden = !supportsProjectContext(focus);
    if (context.hidden) context.querySelector('select').value = '';
  }

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
      <form data-review-form aria-labelledby="review-setup-title">
        <div class="review-setup-heading"><h2 id="review-setup-title">New loop</h2></div>
        <fieldset class="review-scope"><legend>Project &amp; scope</legend>
        <label class="review-project">Project<select data-review-project required aria-label="Review project"></select></label>
        <label class="review-project-context">Project context<select data-review-prompt-context aria-label="Project context">
          <option value="">General project</option><option value="personal">Personal project</option>
        </select></label>
        </fieldset>
        <fieldset class="review-limits"><legend>Review settings</legend>
        <label>Review type<select data-review-focus aria-label="Review type"></select></label>
        <label class="review-priority">Finding priority<select data-review-priority aria-label="Review and fix priority limit">
          <option value="P0">Critical only · P0</option><option value="P1">High and critical · P0–P1</option>
          <option value="P2" selected>Medium and higher · P0–P2</option><option value="P3">All priorities · P0–P3</option>
        </select></label>
        <label>Round limit<input data-review-limit type="number" min="1" max="20" value="5" required aria-describedby="review-limit-help"></label>
        <p id="review-limit-help" class="review-field-help">Each round reviews the project and commits fixes when findings are found. Stops when no findings remain or the limit is reached.</p>
        </fieldset>
        <details class="review-execution-options" open><summary>Model &amp; speed</summary>
        <fieldset class="review-execution"><legend class="review-execution-legend">Execution settings</legend>
        <label>Review model<select data-review-model required aria-label="Review model"><option value="">Choose a model</option></select></label>
        <label>Review reasoning effort<select data-review-effort aria-label="Review reasoning effort"><option value="">Model default</option></select></label>
        <label>Fix model<select data-fix-model required aria-label="Fix model"><option value="">Choose a model</option></select></label>
        <label>Fix reasoning effort<select data-fix-effort aria-label="Fix reasoning effort"><option value="">Model default</option></select></label>
        <label>Response speed<select data-review-speed aria-label="Response speed"><option value="standard" selected>Standard</option><option value="fast">Fast</option></select></label>
        </fieldset>
        </details>
        <p class="review-availability" data-review-availability role="status" hidden></p>
        <div data-review-error role="alert" hidden></div>
        <div class="review-form-footer">
          <button type="submit" data-review-start>Start review &amp; fix <span aria-hidden="true">→</span></button>
        </div>
      </form>
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

  function createCard(loop) {
    const card = document.createElement('article');
    card.className = 'review-activity';
    card.dataset.reviewActivity = '';
    card.dataset.loopId = loop.id;
    card.innerHTML = `
      <div class="review-section-heading"><h2 data-review-project-name></h2><span data-review-badge></span></div>
      <div data-review-context class="review-context"></div>
        <div data-review-status role="status" aria-live="polite"></div>
        <div class="review-round-progress" data-review-round-progress hidden><div><span>Rounds completed</span><span data-review-round-count></span></div><progress data-review-meter aria-label="Completed review rounds" value="0" max="5"></progress></div>
        <div class="review-controls" data-review-controls></div>
        <div class="review-live" data-review-live hidden>
          <div class="review-live-heading"><strong data-review-step></strong><button type="button" data-review-current-task hidden>Open chat ↗</button></div>
          <div class="review-prompt" data-review-current-prompt>
            <div class="review-prompt-heading"><span data-review-current-label>Current prompt</span><span data-review-current-title></span></div>
            <p data-review-current-note></p><pre data-review-current-text></pre>
          </div>
          <div class="review-prompt" data-review-upcoming-prompt>
            <div class="review-prompt-heading"><span>Up next</span><span data-review-upcoming-title></span></div>
            <p data-review-upcoming-note></p><pre data-review-upcoming-text></pre>
          </div>
          <p class="review-next-message" data-review-next-message></p>
        </div>
        <ol data-review-rounds aria-label="Review rounds"></ol>`;
    return card;
  }

  function renderNavigationStatus(snapshot) {
    const spinner = document.querySelector('[data-review-navigation-running]');
    if (!spinner) return;
    const runningCount = snapshot.loops.filter(loop => ['waiting', 'running'].includes(loop.phase)).length;
    const label = `${runningCount} running review ${runningCount === 1 ? 'loop' : 'loops'}`;
    spinner.hidden = runningCount === 0;
    spinner.setAttribute('aria-label', label);
    spinner.setAttribute('title', label);
    spinner.querySelector('[data-review-navigation-running-count]').textContent = String(runningCount);
  }

  function renderReasoningOptions(snapshot, pendingAction, kind = 'review') {
    const root = panel();
    if (!root) return;
    const model = (snapshot.models || []).find(item => item.modelID === root.querySelector(`[data-${kind}-model]`).value);
    const select = root.querySelector(`[data-${kind}-effort]`);
    const selected = select.value;
    select.innerHTML = '<option value="">Model default</option>' + (model?.supportedReasoningEfforts || []).map(value => `<option value="${escape(value)}">${escape(reasoningLabel(value))}</option>`).join('');
    if (model?.supportedReasoningEfforts.includes(selected)) select.value = selected;
    select.disabled = !model || !!pendingAction;
  }

  function render(snapshot, pendingAction, retainedLoopIDs = new Set()) {
    finishedLoopIDs = new Set(snapshot.finishedLoopIDs || []);
    renderNavigationStatus(snapshot);
    const root = panel();
    if (!root) return;
    const { loops, projects, error } = snapshot;
    const models = snapshot.models || [];
    reviewTypes = snapshot.reviewTypes || [];
    const nextReviewTypesSignature = JSON.stringify(reviewTypes);
    if (nextReviewTypesSignature !== reviewTypesSignature) {
      const focusSelect = root.querySelector('[data-review-focus]');
      const selected = focusSelect.value;
      focusSelect.innerHTML = reviewTypes.map(type => `<option value="${escape(type.id)}">${escape(type.label)}</option>`).join('');
      if (reviewTypes.some(type => type.id === selected)) focusSelect.value = selected;
      reviewTypesSignature = nextReviewTypesSignature;
    }
    const nextModelsSignature = JSON.stringify(models);
    if (nextModelsSignature !== modelsSignature) {
      for (const kind of ['review', 'fix']) {
        const modelSelect = root.querySelector(`[data-${kind}-model]`);
        const selected = modelSelect.value;
        modelSelect.innerHTML = '<option value="">Choose a model</option>' + models.map(model => `<option value="${escape(model.modelID)}">${escape(model.displayName)}</option>`).join('');
        if (selected) {
          if (!models.some(model => model.modelID === selected)) modelSelect.add(new Option(`Unavailable · ${selected}`, selected));
          modelSelect.value = selected;
        }
        renderReasoningOptions(snapshot, pendingAction, kind);
      }
      modelsSignature = nextModelsSignature;
    }
    const select = root.querySelector('[data-review-project]');
    const busyProjects = new Set(loops.filter(loop => !isFinished(loop)).map(loop => loop.project.id));
    const availableProjects = projects.filter(project => !busyProjects.has(project.id));
    const signature = JSON.stringify([projects, [...busyProjects]]);
    if (signature !== projectsSignature) {
      const selected = select.value;
      select.innerHTML = projects.length ? projects.map(project => `<option value="${escape(project.id)}" ${busyProjects.has(project.id) ? 'disabled' : ''}>${escape(project.name)}${busyProjects.has(project.id) ? ' · Loop active' : ''}</option>`).join('') : '<option value="">No local projects available</option>';
      select.value = availableProjects.some(project => project.id === selected) ? selected : availableProjects[0]?.id || '';
      projectsSignature = signature;
    }
    root.querySelectorAll('[data-review-form] input, [data-review-form] select, [data-review-start]').forEach(element => { element.disabled = !!pendingAction || !availableProjects.length; });
    for (const kind of ['review', 'fix']) root.querySelector(`[data-${kind}-effort]`).disabled ||= !root.querySelector(`[data-${kind}-model]`).value;
    renderReviewSettings();
    root.querySelector('[data-review-start]').innerHTML = pendingAction?.kind === 'start' ? 'Starting…' : 'Start review &amp; fix <span aria-hidden="true">→</span>';
    const activeCount = loops.filter(loop => !isFinished(loop)).length;
    const current = loops.filter(loop => !isFinished(loop) || retainedLoopIDs.has(loop.id));
    root.querySelector('[data-review-empty]').hidden = current.length > 0;
    root.querySelector('[data-review-active-count]').textContent = current.length;
    const availability = root.querySelector('[data-review-availability]');
    availability.hidden = availableProjects.length > 0;
    availability.textContent = projects.length ? 'Every project already has an active loop. Finish or stop a loop to start another.' : 'No local projects available. Add a local project in Codex to start a loop.';
    root.querySelector('[data-review-overview]').textContent = loops.length ? `${activeCount} active · ${loops.length} total` : '';
    const notice = root.querySelector('[data-review-error]');
    notice.hidden = !error;
    notice.textContent = error || '';
    renderCards(root.querySelector('[data-review-board]'), current, snapshot, pendingAction, retainedLoopIDs);
    const history = loops.filter(loop => isFinished(loop) && !retainedLoopIDs.has(loop.id)).reverse();
    root.querySelector('[data-review-history]').hidden = !history.length;
    root.querySelector('[data-review-history-count]').textContent = history.length;
    const historySelect = root.querySelector('[data-review-history-select]');
    const selectedID = historySelect.value;
    const options = history.map(loop => `<option value="${escape(loop.id)}">${escape(loop.project.name)} · ${escape(phaseLabel(loop))} · ${loop.rounds.filter(round => round.result && round.result.outcome !== 'blocked').length} of ${loop.maxRounds} rounds</option>`).join('');
    if (historySelect.dataset.options !== options) {
      historySelect.innerHTML = options;
      historySelect.dataset.options = options;
      historySelect.value = history.some(loop => loop.id === selectedID) ? selectedID : history[0]?.id || '';
    }
    const selectedIndex = history.findIndex(loop => loop.id === historySelect.value);
    root.querySelectorAll('[data-review-history-action]').forEach(button => {
      button.disabled = !!pendingAction || (button.dataset.reviewHistoryAction === 'deleteOlder' && selectedIndex >= history.length - 1);
    });
    renderCards(root.querySelector('[data-review-history-card]'), history.filter(loop => loop.id === historySelect.value), snapshot, pendingAction);
  }

  function phaseLabel(loop) {
    return loop.phase === 'limitReached' ? 'Round limit reached' : loop.phase.charAt(0).toUpperCase() + loop.phase.slice(1);
  }

  function renderCards(board, loops, snapshot, pendingAction, retainedLoopIDs = new Set()) {
    const cards = new Map([...board.children].map(card => [card.dataset.loopId, card]));
    for (const [index, loop] of loops.entries()) {
      const card = cards.get(loop.id) || createCard(loop);
      if (board.children[index] !== card) board.insertBefore(card, board.children[index] || null);
      renderCard(card, loop, snapshot.progress?.[loop.id], pendingAction, retainedLoopIDs.has(loop.id));
      cards.delete(loop.id);
    }
    cards.forEach(card => card.remove());
  }

  function renderCard(root, loop, progress, pendingAction, retained) {
    root.querySelector('[data-review-project-name]').textContent = loop.project.name;
    root.setAttribute('aria-label', loop.project.name);
    const badge = root.querySelector('[data-review-badge]');
    badge.textContent = phaseLabel(loop);
    badge.dataset.phase = loop.phase;
    const modelLabel = (label, selection) => `<span>${label}: ${selection ? `${escape(selection.modelID)}${selection.reasoningEffort ? ` · ${escape(reasoningLabel(selection.reasoningEffort))}` : ''}` : 'Not recorded'}</span>`;
    const focusLabel = reviewTypes.find(type => type.id === loop.focus)?.label || loop.focus || '';
    root.querySelector('[data-review-context]').innerHTML = `<span>${escape(focusLabel)}</span>${loop.priorityLimit ? `<span>${loop.priorityLimit === 'P0' ? 'P0' : `P0–${escape(loop.priorityLimit)}`}</span>` : ''}<span>${loop.speed === 'fast' ? 'Fast' : 'Standard'}</span>${modelLabel('Review', loop.reviewSelection)}${modelLabel('Fix', loop.fixSelection)}`;
    root.querySelector('[data-review-status]').textContent = pendingAction?.loopID === loop.id
      ? ({ pause: 'Requesting pause…', resume: 'Resuming loop…', stop: 'Stopping loop…' }[pendingAction.kind] || 'Saving…')
      : loop.message || '';
    const completedRounds = loop.rounds.filter(round => round.result && round.result.outcome !== 'blocked').length;
    root.querySelector('[data-review-round-progress]').hidden = false;
    root.querySelector('[data-review-round-count]').textContent = `${completedRounds} of ${loop.maxRounds}`;
    const meter = root.querySelector('[data-review-meter]');
    meter.max = loop.maxRounds;
    meter.value = completedRounds;
    renderProgress(root, loop, progress);
    const controls = root.querySelector('[data-review-controls]');
    controls.innerHTML = isFinished(loop) ? (retained ? `<button type="button" data-review-clear="${escape(loop.id)}">Move to history</button>` : '') : `${['paused', 'blocked'].includes(loop.phase)
      ? '<button type="button" data-review-action="resume">Resume</button>'
      : `<button type="button" data-review-action="pause" ${loop.pauseRequested ? 'disabled' : ''}>${loop.pauseRequested ? 'Pausing after round…' : loop.phase === 'running' ? 'Pause after round' : 'Pause'}</button>`}
      <button type="button" data-review-action="stop">Stop loop</button>`;
    controls.querySelectorAll('button').forEach(button => { button.dataset.reviewLoopID = loop.id; });
    if (pendingAction) controls.querySelectorAll('button').forEach(button => { button.disabled = true; });
    const expandedRounds = new Set(root.dataset.renderedLoop === loop?.id ? [...root.querySelectorAll('[data-review-rounds] details[open]')].map(details => details.dataset.round) : []);
    root.dataset.renderedLoop = loop?.id || '';
    root.querySelector('[data-review-rounds]').innerHTML = (loop?.rounds || []).map(round => `<li>
      <div class="review-round-number" aria-hidden="true">${round.number}</div><div class="review-round-body"><div class="review-round-heading">
      ${round.threadID ? `<button type="button" data-review-thread="${escape(round.threadID)}">Review ${round.number}</button>` : `Review ${round.number}`}
      <span>${escape(({ clean: 'No findings', fixed: 'Fixes committed', withdrawn: 'Findings withdrawn', blocked: 'Blocked' }[round.result?.outcome]) || (round.fixRequested ? 'Addressing findings' : round.review ? `${round.review.findings.length} findings` : 'Reviewing'))}${round.result?.commit ? ` · ${escape(round.result.commit.slice(0, 8))}` : ''}</span></div>
      ${round.review?.findings?.length ? `<ul class="review-round-findings" aria-label="Findings from review ${round.number}">${round.review.findings.map(finding => `<li>
        <div class="review-finding-heading">${finding.priority ? `<span class="review-finding-priority" data-priority="${escape(finding.priority)}">${escape(finding.priority)}</span>` : ''}<strong>${escape(finding.title)}</strong></div>
        <p>${findingBody(finding.body, loop.id)}</p>
      </li>`).join('')}</ul>` : ''}
      ${round.result?.summary ? `<details class="review-round-details" data-round="${round.number}" ${expandedRounds.has(String(round.number)) ? 'open' : ''}><summary>View summary</summary><p>${escape(round.result.summary)}</p></details>` : ''}
    </div></li>`).join('');
  }
  function renderProgress(root, loop, progress) {
    const live = root.querySelector('[data-review-live]');
    live.hidden = !loop || !progress;
    if (live.hidden) return;
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
    reviewTypesSignature = '';
  }

  return { createPage, render, renderReasoningOptions, renderReviewSettings, renderNavigationStatus, reset, usesPriorities, supportsProjectContext };
})();
