const reviewLoopSetupView = (() => {
  let projectsSignature = '';
  let modelsSignature = '';
  let reviewTypesSignature = '';
  let reviewTypes = [];
  const escape = domUtils.escapeHTML;
  const panel = () => document.querySelector('[data-review-loop]');
  const usesPriorities = focus => reviewTypes.find(type => type.id === focus)?.usesPriorities === true;
  const supportsLiveTesting = focus => reviewTypes.find(type => type.id === focus)?.supportsLiveTesting === true;
  const supportsProjectContext = focus => reviewTypes.find(type => type.id === focus)?.supportsProjectContext === true;

  function formMarkup() {
    return `
      <form data-review-form aria-labelledby="review-setup-title">
        <div class="review-setup-heading"><h2 id="review-setup-title">New loop</h2></div>
        <fieldset class="review-scope"><legend>Project &amp; scope</legend>
        <label class="review-project">Project<select data-review-project required aria-label="Review project"></select></label>
        <label class="review-project-context">Project context<select data-review-prompt-context aria-label="Project context">
          <option value="">General project</option><option value="personal">Personal project</option>
        </select></label>
        </fieldset>
        <fieldset class="review-limits"><legend>Review settings</legend>
        <label>Review type<select data-review-focus aria-label="Review type" aria-describedby="review-type-help"></select></label>
        <p id="review-type-help" class="review-field-help" data-review-type-help></p>
        <label class="review-priority">Finding priority<select data-review-priority aria-label="Review and fix priority limit">
          <option value="P0">Critical only · P0</option><option value="P1">High and critical · P0–P1</option>
          <option value="P2" selected>Medium and higher · P0–P2</option><option value="P3">All priorities · P0–P3</option>
        </select></label>
        <label class="review-live-testing">Live testing<select data-review-live-testing aria-label="Live testing" aria-describedby="review-live-testing-help"><option value="false" selected>Off</option><option value="true">On</option></select></label>
        <p id="review-live-testing-help" class="review-field-help review-live-testing-help">Include live testing alongside the normal review.</p>
        <label class="review-extension">Reload browser extension<select data-review-extension aria-label="Reload browser extension before testing" aria-describedby="review-extension-help"><option value="false" selected>No</option><option value="true">Yes</option></select></label>
        <p id="review-extension-help" class="review-field-help review-extension-help">Use Computer Use to reload the extension before live testing.</p>
        <label class="review-remote-push">Remote push<select data-review-push aria-label="Push review fixes to remote"><option value="false" selected>Keep commits local</option><option value="true">Push after each fix round</option></select></label>
        <p class="review-field-help review-push-help">Pushing requires a configured remote. Uses the branch’s upstream, or origin (or the sole remote) for a new branch. Push failures stop the loop.</p>
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
    `;
  }

  function renderReviewSettings() {
    const root = panel();
    if (!root) return;
    const focus = root.querySelector('[data-review-focus]').value;
    root.querySelector('[data-review-type-help]').textContent = reviewTypes.find(type => type.id === focus)?.scopeDescription || '';
    root.querySelector('.review-priority').hidden = !usesPriorities(focus);
    const liveTesting = root.querySelector('.review-live-testing');
    liveTesting.hidden = !supportsLiveTesting(focus);
    root.querySelector('.review-live-testing-help').hidden = liveTesting.hidden;
    if (liveTesting.hidden) liveTesting.querySelector('select').value = 'false';
    const extension = root.querySelector('.review-extension');
    extension.hidden = liveTesting.hidden || liveTesting.querySelector('select').value !== 'true';
    root.querySelector('.review-extension-help').hidden = extension.hidden;
    if (extension.hidden) extension.querySelector('select').value = 'false';
    const context = root.querySelector('.review-project-context');
    context.hidden = !supportsProjectContext(focus);
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

  function render(snapshot, pendingAction, isFinished) {
    const root = panel();
    if (!root) return;
    const { loops, projects } = snapshot;
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
      select.innerHTML = projects.length ? projects.map(project => `<option value="${escape(project.id)}" ${busyProjects.has(project.id) ? 'disabled' : ''}>${escape(project.name)}${busyProjects.has(project.id) ? ' · Loop active' : ''}</option>`).join('') : '<option value="">No eligible projects</option>';
      select.value = availableProjects.some(project => project.id === selected) ? selected : availableProjects[0]?.id || '';
      projectsSignature = signature;
    }
    root.querySelectorAll('[data-review-form] input, [data-review-form] select, [data-review-start]').forEach(element => { element.disabled = !!pendingAction || !availableProjects.length; });
    for (const kind of ['review', 'fix']) root.querySelector(`[data-${kind}-effort]`).disabled ||= !root.querySelector(`[data-${kind}-model]`).value;
    renderReviewSettings();
    root.querySelector('[data-review-start]').innerHTML = pendingAction?.kind === 'start' ? 'Starting…' : 'Start review &amp; fix <span aria-hidden="true">→</span>';
    const availability = root.querySelector('[data-review-availability]');
    availability.hidden = availableProjects.length > 0;
    availability.textContent = projects.length ? 'Every project already has an active loop. Finish or stop a loop to start another.' : 'Review loops require a local project with one folder. Add or choose a single-folder project in Codex.';
  }

  function reset() {
    projectsSignature = '';
    modelsSignature = '';
    reviewTypesSignature = '';
  }

  return { formMarkup, render, renderReasoningOptions, renderReviewSettings, reset, usesPriorities, supportsProjectContext, supportsLiveTesting };
})();
