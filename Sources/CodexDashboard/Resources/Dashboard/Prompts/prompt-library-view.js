const promptLibraryView = (() => {
  function selectOptions(options, selectedValue) {
    const availableOptions = options.some(([value]) => value === selectedValue) || !selectedValue
      ? options
      : [[selectedValue, `Saved model · ${selectedValue}`], ...options];
    return availableOptions.map(([value, label]) => (
      `<option value="${dashboardElements.escapeHTML(value)}"${value === selectedValue ? ' selected' : ''}>${dashboardElements.escapeHTML(label)}</option>`
    )).join('');
  }

  function presetSummary(preset) {
    if (!preset) return [];
    return [
      presetOptions.models.find(([value]) => value === preset.model)?.[1]
        || (preset.model ? `Saved model · ${preset.model}` : undefined),
      presetOptions.reasoningEfforts.find(([value]) => value === preset.reasoningEffort)?.[1],
      presetOptions.speeds.find(([value]) => value === preset.speed)?.[1],
    ].filter(Boolean);
  }

  function scopeKey(scope) {
    const normalized = promptStore.normalizeScope(scope);
    return normalized.type === 'project'
      ? `project:${normalized.projectPath}`
      : 'global';
  }

  function promptMatchesScope(prompt, scope) {
    return scopeKey(prompt.scope) === scopeKey(scope);
  }

  function render({ dialogState, scopeProject, searchTerm, searchSelection } = {}) {
  const dialog = document.getElementById(dashboardElements.elementIDs.promptDialog);
  const content = dialog?.querySelector('[data-prompt-content]');
  if (!content) return;
  if (dialogState.mode === 'createSection') {
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-section-form>
        <label>Section name<input name="sectionName" autocomplete="off" maxlength="80" placeholder="e.g. Code review" required /></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Create section</button>
        </div>
      </form>`;
    content.querySelector('[name="sectionName"]')?.focus();
    return;
  }
  if (dialogState.mode === 'renameSection') {
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-section-rename-form>
        <label>Section name<input name="sectionName" autocomplete="off" maxlength="80" value="${dashboardElements.escapeHTML(dialogState.section)}" required /></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Rename section</button>
        </div>
      </form>`;
    content.querySelector('[name="sectionName"]')?.focus();
    return;
  }
  if (dialogState.mode !== 'list') {
    const prompt = dialogState.mode === 'edit'
      ? promptStore.prompts.find((item) => item.id === dialogState.promptID)
      : undefined;
    const sectionNames = [...promptStore.sections]
      .sort((left, right) => left.localeCompare(right));
    const promptScope = promptStore.normalizeScope(prompt?.scope);
    const selectedScope = prompt
      ? promptScope.type
      : (scopeProject ? 'project' : 'global');
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-form>
        <label>Name<input name="name" autocomplete="off" maxlength="80" placeholder="e.g. Review this code" value="${dashboardElements.escapeHTML(prompt?.name || '')}" required /></label>
        <label>Section<input name="section" autocomplete="off" maxlength="80" list="dashboard-prompt-sections" placeholder="${dashboardElements.escapeHTML(promptLibraryContract.defaultSection)}" value="${dashboardElements.escapeHTML(promptStore.normalizeSection(prompt?.section))}" /><datalist id="dashboard-prompt-sections">${sectionNames.map((section) => `<option value="${dashboardElements.escapeHTML(section)}"></option>`).join('')}</datalist></label>
        <label>Scope<select name="scope"><option value="global"${selectedScope === 'global' ? ' selected' : ''}>All projects</option>${scopeProject ? `<option value="project"${selectedScope === 'project' ? ' selected' : ''}>This project · ${dashboardElements.escapeHTML(scopeProject.name)}</option>` : ''}</select></label>
        <label class="dashboard-prompt-preset-toggle"><input type="checkbox" name="hasPreset"${prompt?.preset ? ' checked' : ''} />Save a model preset</label>
        <fieldset class="dashboard-prompt-preset-fields" data-prompt-preset-fields${prompt?.preset ? '' : ' disabled'}>
          <legend>Model preset</legend>
          <label>Model<select name="presetModel">${selectOptions(presetOptions.models, prompt?.preset?.model || promptLibraryContract.defaults.model)}</select></label>
          <label>Effort<select name="presetReasoningEffort">${selectOptions(presetOptions.reasoningEfforts, prompt?.preset?.reasoningEffort || promptLibraryContract.defaults.reasoningEffort)}</select></label>
          <label>Speed<select name="presetSpeed">${selectOptions(presetOptions.speeds, prompt?.preset?.speed || promptLibraryContract.defaults.speed)}</select></label>
        </fieldset>
        <label>Prompt<textarea name="content" rows="8" placeholder="Write the prompt you want to reuse…" required>${dashboardElements.escapeHTML(prompt?.content || '')}</textarea></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Save prompt</button>
        </div>
      </form>`;
    content.querySelector('[name="name"]')?.focus();
    return;
  }
  const query = searchTerm.trim().toLowerCase();
  const matchingPrompts = query ? promptStore.prompts.filter((prompt) => (
    `${prompt.name} ${prompt.section} ${prompt.content} ${presetSummary(prompt.preset).join(' ')}`
      .toLowerCase().includes(query)
  )) : promptStore.prompts;
  const renderPromptRows = (sectionPrompts) => sectionPrompts.map((prompt) => `
    <article class="dashboard-prompt-row" data-prompt-row-id="${dashboardElements.escapeHTML(prompt.id)}" draggable="true">
      <span class="dashboard-prompt-drag-handle" aria-hidden="true" title="Drag to reorder">⠿</span>
      <div class="dashboard-prompt-row-main">
        <button type="button" class="dashboard-prompt-use" data-prompt-use="${dashboardElements.escapeHTML(prompt.id)}">
          <strong>${dashboardElements.escapeHTML(prompt.name)}</strong>
          <span>${dashboardElements.escapeHTML(prompt.content)}</span>
          ${presetSummary(prompt.preset).length ? `<span class="dashboard-prompt-preset-summary">${presetSummary(prompt.preset).map((item) => `<em>${dashboardElements.escapeHTML(item)}</em>`).join('')}</span>` : ''}
        </button>
        <label class="dashboard-prompt-use-preset"><input type="checkbox" data-prompt-use-preset="${dashboardElements.escapeHTML(prompt.id)}"${prompt.usePreset ? ' checked' : ''}${prompt.preset ? '' : ' disabled'} />Use model preset</label>
      </div>
      <div class="dashboard-prompt-row-actions">
        <button type="button" data-prompt-move-up="${dashboardElements.escapeHTML(prompt.id)}" aria-label="Move ${dashboardElements.escapeHTML(prompt.name)} up">↑</button>
        <button type="button" data-prompt-move-down="${dashboardElements.escapeHTML(prompt.id)}" aria-label="Move ${dashboardElements.escapeHTML(prompt.name)} down">↓</button>
        <button type="button" data-prompt-edit="${dashboardElements.escapeHTML(prompt.id)}" aria-label="Edit ${dashboardElements.escapeHTML(prompt.name)}">Edit</button>
        <button type="button" data-prompt-delete="${dashboardElements.escapeHTML(prompt.id)}" aria-label="Delete ${dashboardElements.escapeHTML(prompt.name)}">Delete</button>
      </div>
    </article>`).join('');
  const scopeGroups = [];
  if (scopeProject) {
    scopeGroups.push({
      title: `This project · ${scopeProject.name}`,
      scope: { type: 'project', projectPath: scopeProject.path },
      prompts: matchingPrompts.filter((prompt) => promptMatchesScope(
        prompt,
        { type: 'project', projectPath: scopeProject.path },
      )),
      includeEmptySections: false,
    });
  }
  scopeGroups.push({
    title: 'Global',
    scope: { type: 'global' },
    prompts: matchingPrompts.filter((prompt) => promptMatchesScope(prompt, { type: 'global' })),
    includeEmptySections: true,
  });
  const groups = scopeGroups.map((group, groupIndex) => {
    const groupedPrompts = new Map();
    if (group.includeEmptySections && !query) {
      promptStore.sections.forEach((section) => groupedPrompts.set(section, []));
    }
    group.prompts.forEach((prompt) => {
      const section = promptStore.normalizeSection(prompt.section);
      if (!groupedPrompts.has(section)) groupedPrompts.set(section, []);
      groupedPrompts.get(section).push(prompt);
    });
    const orderedSections = [...groupedPrompts.entries()].sort(([left], [right]) => {
      if (left === promptLibraryContract.defaultSection) return -1;
      if (right === promptLibraryContract.defaultSection) return 1;
      return left.localeCompare(right);
    });
    const sections = orderedSections.map(([section, sectionPrompts], sectionIndex) => {
      const collapsed = promptStore.collapsedSections.has(section);
      const sectionBodyID = `dashboard-prompt-section-${groupIndex}-${sectionIndex}`;
      const canManageSection = group.scope.type === 'global'
        && section !== promptLibraryContract.defaultSection;
      return `
        <section class="dashboard-prompt-section${collapsed ? ' is-collapsed' : ''}" data-prompt-section="${dashboardElements.escapeHTML(section)}" data-prompt-scope-key="${dashboardElements.escapeHTML(scopeKey(group.scope))}">
          <button type="button" class="dashboard-prompt-section-toggle" data-prompt-section-toggle="${dashboardElements.escapeHTML(section)}" aria-expanded="${String(!collapsed)}" aria-controls="${sectionBodyID}">
            <span class="dashboard-prompt-section-title"><span class="dashboard-prompt-section-chevron" aria-hidden="true">›</span><strong>${dashboardElements.escapeHTML(section)}</strong></span>
            <span class="dashboard-prompt-section-count">${sectionPrompts.length}</span>
          </button>
          <div class="dashboard-prompt-section-actions">
            ${canManageSection ? `<button type="button" data-prompt-section-rename="${dashboardElements.escapeHTML(section)}" aria-label="Rename ${dashboardElements.escapeHTML(section)} section">Rename</button><button type="button" data-prompt-section-delete="${dashboardElements.escapeHTML(section)}" aria-label="Delete ${dashboardElements.escapeHTML(section)} section">Delete</button>` : ''}
          </div>
          <div class="dashboard-prompt-section-body" id="${sectionBodyID}"${collapsed ? ' hidden' : ''}>${renderPromptRows(sectionPrompts)}</div>
        </section>`;
    }).join('');
    const emptyMessage = query ? 'No matching prompts' : 'No prompts saved here yet';
    return `
      <section class="dashboard-prompt-scope" data-prompt-scope="${dashboardElements.escapeHTML(scopeKey(group.scope))}">
        <h3>${dashboardElements.escapeHTML(group.title)}</h3>
        ${sections || `<div class="dashboard-prompt-scope-empty">${emptyMessage}</div>`}
      </section>`;
  }).join('');
  content.innerHTML = `
    <div class="dashboard-prompt-tools">
      <label class="dashboard-prompt-search"><span class="sr-only">Search prompts</span><input type="search" data-prompt-search value="${dashboardElements.escapeHTML(searchTerm)}" /></label>
    </div>
    <div class="dashboard-prompt-list">
      ${groups}
    </div>
    <div class="dashboard-prompt-create-actions">
      <button type="button" class="dashboard-prompt-new dashboard-prompt-new-primary" data-prompt-new>+ New prompt</button>
      <button type="button" class="dashboard-prompt-new dashboard-prompt-new-secondary" data-prompt-new-section>+ New section</button>
    </div>`;
  const search = content.querySelector('[data-prompt-search]');
  search?.focus();
  if (searchSelection) {
    search?.setSelectionRange(searchSelection.start, searchSelection.end);
  }
}


  return { render };
})();
