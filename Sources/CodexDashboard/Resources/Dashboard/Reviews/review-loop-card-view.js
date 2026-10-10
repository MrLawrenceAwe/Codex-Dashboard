const reviewLoopCardView = (() => {
  const escape = domUtils.escapeHTML;

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
        <div data-review-media-setting></div>
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

  function findingsMarkup(round, loopID, findingsState, loopFinished) {
    const completed = !!round.result || loopFinished;
    const previous = findingsState.get(String(round.number));
    const open = previous && previous.completed === completed ? previous.open : !completed;
    return round.review?.findings?.length ? `<details class="review-findings-details" data-round="${round.number}" data-completed="${completed}" ${open ? 'open' : ''}><summary><span class="review-findings-hide">Hide findings</span><span class="review-findings-show">Show findings</span> · ${round.review.findings.length}</summary><ul class="review-round-findings" aria-label="Findings from review ${round.number}">${round.review.findings.map(finding => `<li>
        <div class="review-finding-heading">${finding.priority ? `<span class="review-finding-priority" data-priority="${escape(finding.priority)}">${escape(finding.priority)}</span>` : ''}<strong>${escape(finding.title)}</strong></div>
        <p>${findingBody(finding.body, loopID)}</p>
      </li>`).join('')}</ul></details>` : '';
  }

  function summaryMarkup(round, expandedRounds) {
    return round.result?.summary ? `<details class="review-round-details" data-round="${round.number}" ${expandedRounds.has(String(round.number)) ? 'open' : ''}><summary>View summary</summary><p>${escape(round.result.summary)}</p></details>` : '';
  }

  function roundMarkup(round, loop, expandedRounds, findingsState, loopFinished) {
    return `<li>
      <div class="review-round-number" aria-hidden="true">${round.number}</div><div class="review-round-body"><div class="review-round-heading">
      ${round.threadID ? `<button type="button" data-review-thread="${escape(round.threadID)}">Review ${round.number}</button>` : `Review ${round.number}`}
      <span>${escape(reviewPresentation.roundStatus(round, loop.pushToRemote))}</span></div>
      ${findingsMarkup(round, loop.id, findingsState, loopFinished)}
      ${summaryMarkup(round, expandedRounds)}
    </div></li>`;
  }

  function phaseLabel(loop) {
    if (loop.phase === 'awaitingExtensionReload') return 'Waiting for extension reload';
    return loop.phase === 'limitReached' ? 'Round limit reached' : loop.phase.charAt(0).toUpperCase() + loop.phase.slice(1);
  }

  function renderCards(board, loops, snapshot, pendingAction, retainedLoopIDs, isFinished) {
    const cards = new Map([...board.children].map(card => [card.dataset.loopId, card]));
    for (const [index, loop] of loops.entries()) {
      const card = cards.get(loop.id) || createCard(loop);
      if (board.children[index] !== card) board.insertBefore(card, board.children[index] || null);
      renderCard(card, loop, snapshot.progress?.[loop.id], pendingAction, retainedLoopIDs.has(loop.id), isFinished, snapshot.models || [], snapshot.reviewTypes || []);
      cards.delete(loop.id);
    }
    cards.forEach(card => card.remove());
  }

  function renderCard(root, loop, progress, pendingAction, retained, isFinished, models, reviewTypes) {
    root.querySelector('[data-review-project-name]').textContent = loop.project.name;
    root.setAttribute('aria-label', loop.project.name);
    const badge = root.querySelector('[data-review-badge]');
    badge.textContent = phaseLabel(loop);
    badge.dataset.phase = loop.phase;
    const modelLabel = (label, selection) => `<span>${label}: ${selection ? `${escape(models.find(model => model.modelID === selection.modelID)?.displayName || selection.modelID)}${selection.reasoningEffort ? ` · ${escape(composerPresets.reasoningLabel(selection.reasoningEffort))}` : ''}` : 'Not recorded'}</span>`;
    const reviewTypeLabel = reviewPresentation.reviewTypeLabel(loop.reviewType, reviewTypes);
    root.querySelector('[data-review-context]').innerHTML = `<span>${escape(reviewTypeLabel)}</span>${loop.priorityLimit ? `<span>${loop.priorityLimit === 'P0' ? 'P0' : `P0–${escape(loop.priorityLimit)}`}</span>` : ''}${loop.liveTesting ? '<span>Live testing enabled</span>' : ''}${loop.reloadExtensionBeforeTesting ? '<span>Extension reload enabled</span>' : ''}<span>${loop.speed === 'fast' ? 'Fast' : 'Standard'}</span><span>${loop.pushToRemote ? 'Push fixes to remote' : 'Keep commits local'}</span>${modelLabel('Review', loop.reviewSelection)}${modelLabel('Fix', loop.fixSelection)}`;
    root.querySelector('[data-review-status]').textContent = pendingAction?.loopID === loop.id
      ? ({ pause: 'Requesting pause…', resume: 'Resuming loop…', stop: 'Stopping loop…' }[pendingAction.kind] || 'Saving…')
      : loop.message || '';
    const completedRounds = loop.completedRoundCount;
    root.querySelector('[data-review-round-progress]').hidden = false;
    root.querySelector('[data-review-round-count]').textContent = `${completedRounds} of ${loop.maxRounds}`;
    const meter = root.querySelector('[data-review-meter]');
    meter.max = loop.maxRounds;
    meter.value = completedRounds;
    renderProgress(root, loop, progress);
    const controls = root.querySelector('[data-review-controls]');
    controls.innerHTML = loop.phase === 'stopping' ? '<button type="button" data-review-action="stop">Retry Stop</button>' : isFinished(loop) ? (retained ? `<button type="button" data-review-clear="${escape(loop.id)}">Move to history</button>` : '') : `${loop.phase === 'awaitingExtensionReload'
      ? '<button type="button" data-review-action="resume">Extension reloaded — continue</button>'
      : ['paused', 'blocked'].includes(loop.phase)
      ? '<button type="button" data-review-action="resume">Resume</button>'
      : `<button type="button" data-review-action="pause" ${loop.pauseRequested ? 'disabled' : ''}>${loop.pauseRequested ? 'Pausing after round…' : loop.phase === 'running' ? 'Pause after round' : 'Pause'}</button>`}
      <button type="button" data-review-action="stop">Stop loop</button>`;
    controls.querySelectorAll('button').forEach(button => { button.dataset.reviewLoopID = loop.id; });
    if (pendingAction) controls.querySelectorAll('button').forEach(button => { button.disabled = true; });
    const mediaSetting = root.querySelector('[data-review-media-setting]');
    mediaSetting.hidden = isFinished(loop) || loop.phase === 'stopping' || !loop.liveTesting;
    if (!mediaSetting.hidden) {
      if (!mediaSetting.firstElementChild) mediaSetting.innerHTML = '<label><input type="checkbox" data-review-loop-mute-media> Mute test playback</label>';
      const input = mediaSetting.querySelector('input');
      input.dataset.reviewLoopId = loop.id;
      input.checked = !!loop.muteMedia;
      input.disabled = !!pendingAction;
    }
    const expandedRounds = new Set(root.dataset.renderedLoop === loop?.id ? [...root.querySelectorAll('.review-round-details[open]')].map(details => details.dataset.round) : []);
    const findingsState = new Map(root.dataset.renderedLoop === loop?.id ? [...root.querySelectorAll('.review-findings-details')].map(details => [details.dataset.round, { open: details.open, completed: details.dataset.completed === 'true' }]) : []);
    root.dataset.renderedLoop = loop?.id || '';
    root.querySelector('[data-review-rounds]').innerHTML = loop.rounds.map(round =>
      roundMarkup(round, loop, expandedRounds, findingsState, isFinished(loop))).join('');
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
  return { renderCards, phaseLabel };
})();
