const reviewLoopSetupView = (() => {
  let projectsSignature = '';
  let modelsSignature = '';
  let reviewTypesSignature = '';
  let reviewTypes = [];
  let projects = [];
  let loops = [];
  let pending = null;
  const needsQueue = projectID => loops.some(loop => !loop.isFinished && (loop.project.id === projectID || loop.project.path === projects.find(project => project.id === projectID)?.path));
  const escape = domUtils.escapeHTML;
  const panel = () => document.querySelector('[data-review-loop]');
  const usesPriorities = reviewType => reviewTypes.find(type => type.id === reviewType)?.usesPriorities === true;
  const supportsPreservingUICopy = reviewType => reviewTypes.find(type => type.id === reviewType)?.supportsPreservingUICopy === true;
  const supportsLiveTesting = reviewType => reviewTypes.find(type => type.id === reviewType)?.supportsLiveTesting === true;
  const supportsProjectContext = reviewType => reviewTypes.find(type => type.id === reviewType)?.supportsProjectContext === true;

  function formMarkup() {
    return `
      <form data-review-form aria-labelledby="review-setup-title">
        <div class="review-setup-heading"><h2 id="review-setup-title">New loop</h2></div>
        <fieldset class="review-scope"><legend>Project &amp; scope</legend>
        <label class="review-project">Project<select data-review-project required aria-label="Review project"></select></label>
        <label class="review-project-context">Project context<select data-review-prompt-context aria-label="Project context">
          <option value="">General project</option><option value="personal">Personal project</option>
        </select></label>
        <p class="review-field-help" data-review-workspace-help></p>
        </fieldset>
        <fieldset class="review-limits"><legend>Review settings</legend>
        <label>Review type<select data-review-type aria-label="Review type" aria-describedby="review-type-help"></select></label>
        <p id="review-type-help" class="review-field-help" data-review-type-help></p>
        <label class="review-preserve-ui-copy" hidden><input type="checkbox" data-review-preserve-ui-copy> Keep UI copy unchanged</label>
        <label class="review-priority">Finding priority<select data-review-priority aria-label="Review and fix priority limit">
          <option value="P0">Critical only · P0</option><option value="P1">High and critical · P0–P1</option>
          <option value="P2" selected>Medium and higher · P0–P2</option><option value="P3">All priorities · P0–P3</option>
        </select></label>
        <label>Round limit<input data-review-limit type="number" min="1" max="20" value="5" required aria-describedby="review-limit-help"></label>
        <p id="review-limit-help" class="review-field-help">Stops early when no qualifying findings remain.</p>
        </fieldset>
        <details class="review-execution-options" open><summary>Model &amp; speed</summary>
        <fieldset class="review-execution"><legend class="review-execution-legend">Execution settings</legend>
        <label>Review model<select data-review-model required aria-label="Review model"><option value="">Choose a model</option></select></label>
        <label>Reasoning effort<select data-review-effort aria-label="Review reasoning effort"><option value="">Model default</option></select></label>
        <label>Fix model<select data-fix-model required aria-label="Fix model"><option value="">Choose a model</option></select></label>
        <label>Reasoning effort<select data-fix-effort aria-label="Fix reasoning effort"><option value="">Model default</option></select></label>
        <label>Response speed<select data-review-speed aria-label="Response speed"><option value="standard" selected>Standard</option><option value="fast">Fast</option></select></label>
        </fieldset>
        </details>
        <details class="review-testing-options"><summary>Testing &amp; publishing</summary>
        <fieldset class="review-limits"><legend class="review-visually-hidden">Testing and publishing settings</legend>
        <label class="review-live-testing">Live testing<select data-review-live-testing aria-label="Live testing" aria-describedby="review-live-testing-help"><option value="false" selected>Off</option><option value="true">On</option></select></label>
        <p id="review-live-testing-help" class="review-field-help review-live-testing-help">Test the running app during review.</p>
        <label class="review-extension">Reload browser extension<select data-review-extension aria-label="Reload browser extension before testing" aria-describedby="review-extension-help"><option value="false" selected>No</option><option value="true">Yes</option></select></label>
        <p id="review-extension-help" class="review-field-help review-extension-help">Reload before testing and after fixes that need live verification. Failed reloads wait for you.</p>
        <label class="review-mute-test-playback"><input type="checkbox" data-review-mute-test-playback> Mute test playback</label>
        <label class="review-remote-push">Remote push<select data-review-push aria-label="Push review fixes to remote"><option value="false" selected>Keep commits local</option><option value="true">Push after each fix round</option></select></label>
        <p class="review-field-help review-push-help">Requires an upstream, origin, or sole remote. Diverged history is merged, committed and verified before pushing. Push failures block the loop; resolve them, then Resume.</p>
        </fieldset>
        </details>
        <p class="review-availability" data-review-availability role="status" hidden></p>
        <div data-review-error role="alert" hidden></div>
        <div class="review-form-footer">
          <button type="submit" data-review-start>Start review &amp; fix <span aria-hidden="true">→</span></button>
        </div>
      </form>
    `;
  }

  function readSettings() {
    const root = panel();
    const value = selector => root.querySelector(selector).value;
    const selection = kind => {
      const modelID = value(`[data-${kind}-model]`);
      return modelID ? { modelID, reasoningEffort: value(`[data-${kind}-effort]`) || null } : null;
    };
    const reviewType = value('[data-review-type]');
    const liveTesting = supportsLiveTesting(reviewType) && value('[data-review-live-testing]') === 'true';
    return {
      kind: needsQueue(value('[data-review-project]')) ? 'queue' : 'start',
      projectID: value('[data-review-project]'),
      reviewSelection: selection('review'),
      fixSelection: selection('fix'),
      reviewType,
      liveTesting,
      preserveUICopy: supportsPreservingUICopy(reviewType) && root.querySelector('[data-review-preserve-ui-copy]').checked,
      reloadExtensionBeforeTesting: liveTesting && value('[data-review-extension]') === 'true',
      muteTestPlayback: liveTesting && root.querySelector('[data-review-mute-test-playback]').checked,
      pushToRemote: projects.find(project => project.id === value('[data-review-project]'))?.workspaceKind !== 'folder' && value('[data-review-push]') === 'true',
      speed: value('[data-review-speed]'),
      promptContext: { kind: supportsProjectContext(reviewType) ? value('[data-review-prompt-context]') || 'general' : 'general' },
      priorityLimit: usesPriorities(reviewType) ? value('[data-review-priority]') : null,
      maxRounds: Number(value('[data-review-limit]')),
    };
  }

  function renderReviewSettings() {
    const root = panel();
    if (!root) return;
    const queued = needsQueue(root.querySelector('[data-review-project]').value);
    root.querySelector('[data-review-start]').innerHTML = ['start', 'queue'].includes(pending?.kind)
      ? (pending.kind === 'queue' ? 'Queueing…' : 'Starting…')
      : queued ? 'Queue review &amp; fix <span aria-hidden="true">→</span>' : 'Start review &amp; fix <span aria-hidden="true">→</span>';
    const availability = root.querySelector('[data-review-availability]');
    availability.hidden = projects.length > 0 && !queued;
    availability.textContent = queued ? 'Runs after earlier loops for this project finish or are stopped. Paused or blocked loops hold the queue.' : 'Choose a local, single-folder project in Codex to start.';
    const folder = projects.find(project => project.id === root.querySelector('[data-review-project]').value)?.workspaceKind === 'folder';
    const push = root.querySelector('[data-review-push]');
    if (folder) push.value = 'false';
    push.disabled = folder || root.querySelector('[data-review-start]').disabled;
    push.querySelector('option[value="false"]').textContent = folder ? 'Save changes in folder' : 'Keep commits local';
    root.querySelector('[data-review-workspace-help]').textContent = folder
      ? 'Fixes are saved and verified in this folder.'
      : 'Fixes are committed locally. Remote push is optional.';
    root.querySelector('.review-push-help').hidden = folder;
    const reviewType = root.querySelector('[data-review-type]').value;
    root.querySelector('[data-review-type-help]').textContent = reviewTypes.find(type => type.id === reviewType)?.scopeDescription || '';
    const preserveUICopy = root.querySelector('.review-preserve-ui-copy');
    preserveUICopy.hidden = !supportsPreservingUICopy(reviewType);
    if (preserveUICopy.hidden) preserveUICopy.querySelector('input').checked = false;
    root.querySelector('.review-priority').hidden = !usesPriorities(reviewType);
    const liveTesting = root.querySelector('.review-live-testing');
    liveTesting.hidden = !supportsLiveTesting(reviewType);
    root.querySelector('.review-live-testing-help').hidden = liveTesting.hidden;
    if (liveTesting.hidden) liveTesting.querySelector('select').value = 'false';
    const extension = root.querySelector('.review-extension');
    extension.hidden = liveTesting.hidden || liveTesting.querySelector('select').value !== 'true';
    root.querySelector('.review-extension-help').hidden = extension.hidden;
    if (extension.hidden) extension.querySelector('select').value = 'false';
    const muteTestPlayback = root.querySelector('.review-mute-test-playback');
    muteTestPlayback.hidden = extension.hidden;
    if (muteTestPlayback.hidden) muteTestPlayback.querySelector('input').checked = false;
    const context = root.querySelector('.review-project-context');
    context.hidden = !supportsProjectContext(reviewType);
    if (context.hidden) context.querySelector('select').value = '';
  }

  function renderReasoningOptions(snapshot, pendingAction, kind = 'review') {
    const root = panel();
    if (!root) return;
    const model = (snapshot.models || []).find(item => item.modelID === root.querySelector(`[data-${kind}-model]`).value);
    const select = root.querySelector(`[data-${kind}-effort]`);
    const selected = select.value;
    select.innerHTML = '<option value="">Model default</option>' + (model?.supportedReasoningEfforts || []).map(value => `<option value="${escape(value)}">${escape(composerPresets.reasoningLabel(value))}</option>`).join('');
    if (model?.supportedReasoningEfforts.includes(selected)) select.value = selected;
    select.disabled = !model || !!pendingAction;
  }

  function render(snapshot, pendingAction) {
    const root = panel();
    if (!root) return;
    loops = snapshot.loops;
    pending = pendingAction;
    projects = snapshot.projects;
    const models = snapshot.models || [];
    reviewTypes = snapshot.reviewTypes || [];
    const nextReviewTypesSignature = JSON.stringify(reviewTypes);
    if (nextReviewTypesSignature !== reviewTypesSignature) {
      const reviewTypeSelect = root.querySelector('[data-review-type]');
      const selected = reviewTypeSelect.value;
      reviewTypeSelect.innerHTML = reviewTypes.map(type => `<option value="${escape(type.id)}">${escape(type.label)}</option>`).join('');
      if (reviewTypes.some(type => type.id === selected)) reviewTypeSelect.value = selected;
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
    const busyProjects = new Set(loops.filter(loop => !loop.isFinished).map(loop => loop.project.id));
    const signature = JSON.stringify([projects, [...busyProjects]]);
    if (signature !== projectsSignature) {
      const selected = select.value;
      select.innerHTML = projects.length ? projects.map(project => `<option value="${escape(project.id)}">${escape(project.name)}${busyProjects.has(project.id) ? ' · Queue available' : ''}</option>`).join('') : '<option value="">No eligible projects</option>';
      select.value = projects.some(project => project.id === selected) ? selected : projects[0]?.id || '';
      projectsSignature = signature;
    }
    root.querySelectorAll('[data-review-form] input, [data-review-form] select, [data-review-start]').forEach(element => { element.disabled = !!pendingAction || !projects.length; });
    for (const kind of ['review', 'fix']) root.querySelector(`[data-${kind}-effort]`).disabled ||= !root.querySelector(`[data-${kind}-model]`).value;
    renderReviewSettings();
  }

  function reset() {
    projectsSignature = '';
    modelsSignature = '';
    reviewTypesSignature = '';
  }

  return { formMarkup, render, renderReasoningOptions, renderReviewSettings, reset, readSettings };
})();
