const reviewLoopCardView = (() => {
  const escape = domUtils.escapeHTML;
  const renderedMarkup = new WeakMap();
  const renderedRounds = new WeakMap();

  function updateMarkup(element, markup) {
    if (renderedMarkup.get(element) === markup) return;
    element.innerHTML = markup;
    renderedMarkup.set(element, markup);
  }

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
      <div class="review-scope-label" data-review-scope-label></div>
        <div class="review-live-heading" data-review-live-heading hidden><strong data-review-step></strong><button type="button" data-review-current-task hidden>Open chat ↗</button></div>
        <div class="review-feedback" data-review-feedback></div>
        <div data-review-status role="status" aria-live="polite"></div>
        <div class="review-round-progress" data-review-round-progress hidden><div><span>Rounds completed</span><span data-review-round-count></span></div><progress data-review-meter aria-label="Completed review rounds" value="0" max="5"></progress></div>
        <div class="review-controls" data-review-controls></div>
        <div data-review-test-playback-setting></div>
        <div class="review-live" data-review-live hidden>
          <details class="review-prompt" data-review-current-prompt>
            <summary class="review-prompt-heading"><span>Configured prompt preview</span><span data-review-current-title></span></summary>
            <p data-review-current-note></p><pre data-review-current-text></pre>
          </details>
          <details class="review-prompt" data-review-upcoming-prompt>
            <summary class="review-prompt-heading"><span>Up next</span><span data-review-upcoming-title></span></summary>
            <p data-review-upcoming-note></p><pre data-review-upcoming-text></pre>
          </details>
          <p class="review-next-message" data-review-next-message></p>
        </div>
        <ol data-review-rounds aria-label="Review rounds"></ol>
        <details class="review-configuration"><summary>Loop settings</summary><div data-review-context class="review-context"></div></details>`;
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
    return `<li data-outcome="${escape(round.result?.outcome || (loop.phase === 'running' && round === loop.rounds.at(-1) ? 'active' : 'pending'))}">
      <div class="review-round-number" aria-hidden="true">${round.number}</div><div class="review-round-body"><div class="review-round-heading">
      ${round.threadID ? `<button type="button" data-review-thread="${escape(round.threadID)}">Review ${round.number}</button>` : `Review ${round.number}`}
      <span>${escape(reviewPresentation.roundStatus(round, loop.pushToRemote, loop.workspaceKind))}</span></div>
      ${findingsMarkup(round, loop.id, findingsState, loopFinished)}
      ${summaryMarkup(round, expandedRounds)}
    </div></li>`;
  }

  function renderCards(board, loops, snapshot, pendingAction, retainedLoopIDs) {
    const cards = new Map([...board.children].map(card => [card.dataset.loopId, card]));
    for (const [index, loop] of loops.entries()) {
      const card = cards.get(loop.id) || createCard(loop);
      if (board.children[index] !== card) board.insertBefore(card, board.children[index] || null);
      renderCard(card, loop, snapshot.progress?.[loop.id], pendingAction, retainedLoopIDs.has(loop.id), snapshot.models || [], snapshot.reviewTypes || []);
      cards.delete(loop.id);
    }
    cards.forEach(card => card.remove());
  }

  function renderCard(root, loop, progress, pendingAction, retained, models, reviewTypes) {
    root.querySelector('[data-review-project-name]').textContent = loop.project.name;
    root.setAttribute('aria-label', loop.project.name);
    const badge = root.querySelector('[data-review-badge]');
    badge.textContent = reviewPresentation.phaseLabel(loop);
    badge.dataset.phase = loop.phase;
    renderSettings(root, loop, models, reviewTypes);
    root.querySelector('[data-review-status]').textContent = pendingAction?.loopID === loop.id
      ? ({ pause: 'Requesting pause…', resume: 'Resuming loop…', stop: 'Stopping loop…' }[pendingAction.kind] || 'Saving…')
      : loop.message || '';
    const completedRounds = loop.completedRoundCount;
    root.querySelector('[data-review-round-progress]').hidden = false;
    root.querySelector('[data-review-round-count]').textContent = `${completedRounds} of ${loop.maxRounds}`;
    const meter = root.querySelector('[data-review-meter]');
    meter.max = loop.maxRounds;
    meter.value = completedRounds;
    root.dataset.phase = loop.phase;
    renderFeedback(root, loop);
    renderProgress(root, loop, progress);
    renderControls(root, loop, pendingAction, retained);
    renderPlaybackSetting(root, loop, pendingAction);
    renderRounds(root, loop);
  }

  function renderSettings(root, loop, models, reviewTypes) {
    const scope = [reviewPresentation.reviewTypeLabel(loop.reviewType, reviewTypes),
      reviewPresentation.priorityLabel(loop.priorityLimit)].filter(Boolean).join(' · ');
    root.querySelector('[data-review-scope-label]').textContent = scope;
    const markup = reviewPresentation.settingsLabels(loop, models, reviewTypes)
      .map(label => `<span>${escape(label)}</span>`).join('');
    updateMarkup(root.querySelector('[data-review-context]'), markup);
  }

  function renderControls(root, loop, pendingAction, retained) {
    const controls = root.querySelector('[data-review-controls]');
    const choices = reviewPresentation.controls(loop, retained);
    const markup = choices.map(control => {
      const attribute = control.action ? `data-review-action="${escape(control.action)}"`
        : `data-review-clear="${escape(control.clear)}"`;
      return `<button type="button" ${attribute}${control.disabled ? ' disabled' : ''}>${escape(control.label)}</button>`;
    }).join('');
    updateMarkup(controls, markup);
    controls.querySelectorAll('button').forEach((button, index) => {
      button.dataset.reviewLoopID = loop.id;
      button.disabled = !!pendingAction || !!choices[index].disabled;
    });
  }

  function renderPlaybackSetting(root, loop, pendingAction) {
    const playbackSetting = root.querySelector('[data-review-test-playback-setting]');
    playbackSetting.hidden = loop.isFinished || loop.phase === 'stopping' || !loop.liveTesting;
    if (!playbackSetting.hidden) {
      if (!playbackSetting.firstElementChild) playbackSetting.innerHTML = '<label><input type="checkbox" data-review-loop-mute-test-playback> Mute test playback</label>';
      const input = playbackSetting.querySelector('input');
      input.dataset.reviewLoopId = loop.id;
      input.checked = !!loop.muteTestPlayback;
      input.disabled = !!pendingAction;
    }
  }

  function renderRounds(root, loop) {
    const rounds = root.querySelector('[data-review-rounds]');
    const signature = JSON.stringify([loop.id, loop.rounds, loop.phase, loop.isFinished, loop.pushToRemote, loop.workspaceKind]);
    if (renderedRounds.get(rounds) !== signature) {
      const expandedRounds = new Set(root.dataset.renderedLoop === loop.id ? [...rounds.querySelectorAll('.review-round-details[open]')].map(details => details.dataset.round) : []);
      const findingsState = new Map(root.dataset.renderedLoop === loop.id ? [...rounds.querySelectorAll('.review-findings-details')].map(details => [details.dataset.round, { open: details.open, completed: details.dataset.completed === 'true' }]) : []);
      root.dataset.renderedLoop = loop.id;
      rounds.innerHTML = loop.rounds.map(round =>
        roundMarkup(round, loop, expandedRounds, findingsState, loop.isFinished)).join('');
      renderedRounds.set(rounds, signature);
    }
  }
  function renderFeedback(root, loop) {
    const stages = reviewPresentation.roundStages(loop);
    const icons = { done: '✓', skipped: '–', blocked: '!', paused: 'Ⅱ', stopped: '■', stopping: '■' };
    const metrics = reviewPresentation.metrics(loop);
    const feedback = root.querySelector('[data-review-feedback]');
    const markup = `
      <div class="review-feedback-heading"><strong>${metrics.roundLabel}</strong></div>
      <ol class="review-stage-track" aria-label="${metrics.roundLabel} progress">${stages.map((stage, index) => `
        <li data-stage="${stage.state}" ${stage.state === 'active' ? 'aria-current="step"' : ''}>
          <span class="review-stage-icon" aria-hidden="true">${icons[stage.state] || index + 1}</span>
          <strong>${stage.label}</strong><span class="review-stage-description">${stage.description}</span>
        </li>`).join('')}</ol>
      <dl class="review-metrics">
        <div><dt>Findings this round</dt><dd>${metrics.findings}</dd></div>
        <div><dt>Findings addressed</dt><dd>${metrics.addressed}</dd></div>
        ${loop.workspaceKind === 'folder' ? '' : `<div><dt>Fix commits</dt><dd>${metrics.commits}</dd></div>`}
      </dl>`;
    updateMarkup(feedback, markup);
  }
  function renderProgress(root, loop, progress) {
    const live = root.querySelector('[data-review-live]');
    live.hidden = !loop || !progress;
    root.querySelector('[data-review-live-heading]').hidden = live.hidden;
    if (live.hidden) return;
    root.querySelector('[data-review-step]').textContent = progress.step;
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
  return { renderCards };
})();
