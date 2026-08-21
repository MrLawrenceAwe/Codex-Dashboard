const promptLibrary = (() => {
  const dialogOwner = Symbol('codex-dashboard.prompt-dialog-owner');
  const insertionGuard = Symbol.for('codex-dashboard.prompt-insertion-guard');
  let dialogModeState = { mode: 'list' };
  let returnFocusElement;
  let promptSearchTerm = '';
  let capturedSelectionText = '';
  let activeProject;
  const presetModelOptions = [
    ['gpt-5.6-sol', '5.6 Sol'],
    ['gpt-5.6-terra', '5.6 Terra'],
    ['gpt-5.6-luna', '5.6 Luna'],
    ['gpt-5.5', '5.5'],
    ['gpt-5.4', '5.4'],
    ['gpt-5.4-mini', '5.4 Mini'],
  ];
  const presetReasoningOptions = [
    ['low', 'Low'], ['medium', 'Medium'],
    ['high', 'High'], ['xhigh', 'Extra High'],
  ];
  const presetSpeedOptions = [
    ['standard', 'Standard'], ['fast', 'Fast'],
  ];

  function selectOptions(options, selectedValue) {
    return options.map(([value, label]) => (
      `<option value="${value}"${value === selectedValue ? ' selected' : ''}>${label}</option>`
    )).join('');
  }

  function presetSummary(preset) {
    if (!preset) return [];
    return [
      presetModelOptions.find(([value]) => value === preset.model)?.[1],
      presetReasoningOptions.find(([value]) => value === preset.reasoningEffort)?.[1],
      presetSpeedOptions.find(([value]) => value === preset.speed)?.[1],
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

  function showStorageError(message) {
    const error = document.querySelector('[data-prompt-storage-error]');
    if (error) {
      if (message) error.textContent = message;
      error.hidden = false;
    }
  }

  function persistLibrary(nextPrompts = promptStore.prompts, nextSections = promptStore.sections) {
    if (promptStore.commitLibrary(nextPrompts, nextSections)) return true;
    showStorageError();
    return false;
  }

  const promptInteractionEventTypes = [
  'pointerdown', 'mousedown', 'click', 'keydown', 'input', 'search', 'change', 'submit',
  'dragstart', 'dragover', 'dragleave', 'drop', 'dragend',
];

  function renderDialog({ searchSelection } = {}) {
  const dialog = document.getElementById(dashboardElements.elementIDs.promptDialog);
  const content = dialog?.querySelector('[data-prompt-content]');
  if (!content) return;
  if (dialogModeState.mode === 'createSection') {
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
  if (dialogModeState.mode === 'renameSection') {
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-section-rename-form>
        <label>Section name<input name="sectionName" autocomplete="off" maxlength="80" value="${dashboardElements.escapeHTML(dialogModeState.section)}" required /></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Rename section</button>
        </div>
      </form>`;
    content.querySelector('[name="sectionName"]')?.focus();
    return;
  }
  if (dialogModeState.mode !== 'list') {
    const prompt = dialogModeState.mode === 'edit'
      ? promptStore.prompts.find((item) => item.id === dialogModeState.promptID)
      : undefined;
    const sectionNames = [...promptStore.sections]
      .sort((left, right) => left.localeCompare(right));
    const promptScope = promptStore.normalizeScope(prompt?.scope);
    const selectedScope = prompt
      ? promptScope.type
      : (activeProject ? 'project' : 'global');
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-form>
        <label>Name<input name="name" autocomplete="off" maxlength="80" placeholder="e.g. Review this code" value="${dashboardElements.escapeHTML(prompt?.name || '')}" required /></label>
        <label>Section<input name="section" autocomplete="off" maxlength="80" list="dashboard-prompt-sections" placeholder="General" value="${dashboardElements.escapeHTML(promptStore.normalizeSection(prompt?.section))}" /><datalist id="dashboard-prompt-sections">${sectionNames.map((section) => `<option value="${dashboardElements.escapeHTML(section)}"></option>`).join('')}</datalist></label>
        <label>Scope<select name="scope"><option value="global"${selectedScope === 'global' ? ' selected' : ''}>All projects</option>${activeProject ? `<option value="project"${selectedScope === 'project' ? ' selected' : ''}>This project · ${dashboardElements.escapeHTML(activeProject.name)}</option>` : ''}</select></label>
        <label class="dashboard-prompt-preset-toggle"><input type="checkbox" name="hasPreset"${prompt?.preset ? ' checked' : ''} />Save a model preset</label>
        <fieldset class="dashboard-prompt-preset-fields" data-prompt-preset-fields${prompt?.preset ? '' : ' disabled'}>
          <legend>Model preset</legend>
          <label>Model<select name="presetModel">${selectOptions(presetModelOptions, prompt?.preset?.model || 'gpt-5.6-sol')}</select></label>
          <label>Effort<select name="presetReasoningEffort">${selectOptions(presetReasoningOptions, prompt?.preset?.reasoningEffort || 'medium')}</select></label>
          <label>Speed<select name="presetSpeed">${selectOptions(presetSpeedOptions, prompt?.preset?.speed || 'standard')}</select></label>
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
  const query = promptSearchTerm.trim().toLowerCase();
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
  if (activeProject) {
    scopeGroups.push({
      title: `This project · ${activeProject.name}`,
      scope: { type: 'project', projectPath: activeProject.path },
      prompts: matchingPrompts.filter((prompt) => promptMatchesScope(
        prompt,
        { type: 'project', projectPath: activeProject.path },
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
      if (left === 'General') return -1;
      if (right === 'General') return 1;
      return left.localeCompare(right);
    });
    const sections = orderedSections.map(([section, sectionPrompts], sectionIndex) => {
      const collapsed = promptStore.collapsedSections.has(section);
      const sectionBodyID = `dashboard-prompt-section-${groupIndex}-${sectionIndex}`;
      const canManageSection = group.scope.type === 'global' && section !== 'General';
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
      <label class="dashboard-prompt-search"><span class="sr-only">Search prompts</span><input type="search" data-prompt-search value="${dashboardElements.escapeHTML(promptSearchTerm)}" /></label>
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

function presentDialog() {
  const dialog = promptLibraryDialog.create(dialogOwner);
  document.body.append(dialog);
  renderDialog();
}

function hideDialog() {
  document.getElementById(dashboardElements.elementIDs.promptDialog)?.remove();
}

function restoreDialog(message) {
  presentDialog();
  showStorageError(message);
}

function open() {
  const composer = codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
  if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
    const start = composer.selectionStart ?? 0;
    const end = composer.selectionEnd ?? start;
    capturedSelectionText = composer.value.slice(start, end);
  } else {
    const selection = window.getSelection();
    capturedSelectionText = selection?.rangeCount && composer?.contains(selection.anchorNode)
      ? selection.toString()
      : '';
  }
  hideDialog();
  returnFocusElement = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : undefined;
  dialogModeState = { mode: 'list' };
  promptSearchTerm = '';
  activeProject = threadDashboard.activeProject();
  presentDialog();
}

function expandedPromptContent(content, clipboardText = '') {
  return content
    .replaceAll('{{selection}}', capturedSelectionText)
    .replaceAll('{{clipboard}}', clipboardText);
}

function close({ restoreFocus = true } = {}) {
  dialogModeState = { mode: 'list' };
  document.getElementById(dashboardElements.elementIDs.promptDialog)?.remove();
  const returnFocus = returnFocusElement;
  returnFocusElement = undefined;
  if (restoreFocus && returnFocus?.isConnected) returnFocus.focus();
}

function savePrompt(form) {
  const values = new FormData(form);
  const name = String(values.get('name') || '').trim();
  const content = String(values.get('content') || '').trim();
  if (!name || !content) return;
  const section = promptStore.resolveSection(values.get('section'));
  const scope = values.get('scope') === 'project' && activeProject
    ? { type: 'project', projectPath: activeProject.path }
    : { type: 'global' };
  const preset = values.has('hasPreset')
    ? promptStore.normalizePreset({
      model: String(values.get('presetModel') || ''),
      reasoningEffort: String(values.get('presetReasoningEffort') || ''),
      speed: String(values.get('presetSpeed') || ''),
    })
    : undefined;
  let nextPrompts;
  if (dialogModeState.mode === 'edit') {
    nextPrompts = promptStore.prompts.map((prompt) => (
      prompt.id === dialogModeState.promptID
        ? { ...prompt, name, section, scope, content, preset }
        : prompt
    ));
  } else {
    nextPrompts = [...promptStore.prompts, {
      id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
      name,
      section,
      scope,
      content,
      preset,
    }];
  }
  const nextSections = promptStore.sections.includes(section)
    ? promptStore.sections
    : [...promptStore.sections, section];
  if (!persistLibrary(nextPrompts, nextSections)) return;
  dialogModeState = { mode: 'list' };
  renderDialog();
}

function createPromptSection(form) {
  const values = new FormData(form);
  const name = String(values.get('sectionName') || '').trim();
  if (!name) return;
  const section = promptStore.resolveSection(name);
  const nextSections = promptStore.sections.includes(section)
    ? promptStore.sections
    : [...promptStore.sections, section];
  if (!persistLibrary(promptStore.prompts, nextSections)) return;
  const nextCollapsedSections = new Set(promptStore.collapsedSections);
  nextCollapsedSections.delete(section);
  promptStore.saveCollapsedSections(nextCollapsedSections);
  promptStore.collapsedSections = nextCollapsedSections;
  dialogModeState = { mode: 'list' };
  renderDialog();
  [...document.querySelectorAll('[data-prompt-section-toggle]')]
    .find((button) => button.dataset.promptSectionToggle === section)?.focus();
}

function renamePromptSection(form) {
  const name = String(new FormData(form).get('sectionName') || '').trim();
  if (!name) return;
  const source = dialogModeState.section;
  const destination = promptStore.normalizeSection(name);
  const conflictingSection = promptStore.sections.find((section) => (
    section !== source
      && section.localeCompare(destination, undefined, { sensitivity: 'accent' }) === 0
  ));
  if (conflictingSection) {
    showStorageError('A section with that name already exists.');
    return;
  }
  const nextPrompts = promptStore.prompts.map((prompt) => (
    promptStore.normalizeSection(prompt.section) === source
      ? { ...prompt, section: destination }
      : prompt
  ));
  const nextSections = promptStore.sections.map((section) => (
    section === source ? destination : section
  ));
  if (!persistLibrary(nextPrompts, nextSections)) return;
  promptStore.collapsedSections.delete(source);
  promptStore.saveCollapsedSections();
  dialogModeState = { mode: 'list' };
  renderDialog();
}

function movePrompt(promptID, offset) {
  const index = promptStore.prompts.findIndex((prompt) => prompt.id === promptID);
  const prompt = promptStore.prompts[index];
  if (!prompt) return;
  const section = promptStore.normalizeSection(prompt.section);
  const promptScopeKey = scopeKey(prompt.scope);
  const sectionIndexes = promptStore.prompts
    .map((item, itemIndex) => ({ item, itemIndex }))
    .filter(({ item }) => (
      promptStore.normalizeSection(item.section) === section
        && scopeKey(item.scope) === promptScopeKey
    ))
    .map(({ itemIndex }) => itemIndex);
  const position = sectionIndexes.indexOf(index);
  const destination = sectionIndexes[position + offset];
  if (destination === undefined) return;
  const nextPrompts = [...promptStore.prompts];
  [nextPrompts[index], nextPrompts[destination]] = [nextPrompts[destination], nextPrompts[index]];
  if (!persistLibrary(nextPrompts, promptStore.sections)) return;
  renderDialog();
  document.querySelector(`[data-prompt-row-id="${CSS.escape(promptID)}"] [data-prompt-move-${offset < 0 ? 'up' : 'down'}]`)?.focus();
}

function handlePromptSubmit(event, form) {
  event.preventDefault();
  if (form.matches('[data-prompt-form]')) savePrompt(form);
  else if (form.matches('[data-prompt-section-form]')) createPromptSection(form);
  else if (form.matches('[data-prompt-section-rename-form]')) renamePromptSection(form);
}

function insertSavedPrompt(prompt) {
  const insert = (clipboardText = '') => {
    if (!composerAdapter.insert(expandedPromptContent(prompt.content, clipboardText))) return false;
    close({ restoreFocus: false });
    return true;
  };
  if ((!prompt.usePreset || !prompt.preset) && !prompt.content.includes('{{clipboard}}')) return insert();
  return (async () => {
    let clipboardText = '';
    if (prompt.content.includes('{{clipboard}}')) {
      try { clipboardText = await navigator.clipboard.readText(); } catch (_) { /* use empty text */ }
    }
    hideDialog();
    if (!await composerAdapter.applyPreset(prompt.usePreset ? prompt.preset : undefined)) {
      restoreDialog('Could not apply this prompt’s composer preset. The prompt was not inserted.');
      return false;
    }
    return insert(clipboardText);
  })();
}

function handlePromptClick(target) {
  if (target.closest('[data-prompt-close]')) close();
  else if (target.closest('[data-prompt-section-toggle]')) {
    const toggle = target.closest('[data-prompt-section-toggle]');
    const section = toggle.dataset.promptSectionToggle;
    if (promptStore.collapsedSections.has(section)) promptStore.collapsedSections.delete(section);
    else promptStore.collapsedSections.add(section);
    promptStore.saveCollapsedSections();
    renderDialog();
    [...document.querySelectorAll('[data-prompt-section-toggle]')]
      .find((button) => button.dataset.promptSectionToggle === section)?.focus();
  } else if (target.closest('[data-prompt-new-section]')) {
    dialogModeState = { mode: 'createSection' };
    renderDialog();
  } else if (target.closest('[data-prompt-section-rename]')) {
    dialogModeState = {
      mode: 'renameSection',
      section: target.closest('[data-prompt-section-rename]').dataset.promptSectionRename,
    };
    renderDialog();
  } else if (target.closest('[data-prompt-section-delete-confirm]')) {
    const section = target.closest('[data-prompt-section-delete-confirm]').dataset.promptSectionDeleteConfirm;
    const nextPrompts = promptStore.prompts.map((prompt) => (
      promptStore.normalizeSection(prompt.section) === section
        ? { ...prompt, section: 'General' }
        : prompt
    ));
    const nextSections = promptStore.sections.filter((item) => item !== section);
    if (!persistLibrary(nextPrompts, nextSections)) return;
    promptStore.collapsedSections.delete(section);
    promptStore.saveCollapsedSections();
    renderDialog();
  } else if (target.closest('[data-prompt-section-delete]')) {
    const button = target.closest('[data-prompt-section-delete]');
    button.dataset.promptSectionDeleteConfirm = button.dataset.promptSectionDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm section deletion; prompts will move to General');
  } else if (target.closest('[data-prompt-move-up]')) {
    movePrompt(target.closest('[data-prompt-move-up]').dataset.promptMoveUp, -1);
  } else if (target.closest('[data-prompt-move-down]')) {
    movePrompt(target.closest('[data-prompt-move-down]').dataset.promptMoveDown, 1);
  } else if (target.closest('[data-prompt-new]')) {
    dialogModeState = { mode: 'create' };
    renderDialog();
  } else if (target.closest('[data-prompt-cancel]')) {
    dialogModeState = { mode: 'list' };
    renderDialog();
  } else if (target.closest('[data-prompt-edit]')) {
    dialogModeState = {
      mode: 'edit',
      promptID: target.closest('[data-prompt-edit]').dataset.promptEdit,
    };
    renderDialog();
  } else if (target.closest('[data-prompt-delete-confirm]')) {
    const id = target.closest('[data-prompt-delete-confirm]').dataset.promptDeleteConfirm;
    const nextPrompts = promptStore.prompts.filter((prompt) => prompt.id !== id);
    if (!persistLibrary(nextPrompts, promptStore.sections)) return;
    renderDialog();
  } else if (target.closest('[data-prompt-delete]')) {
    const button = target.closest('[data-prompt-delete]');
    button.dataset.promptDeleteConfirm = button.dataset.promptDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm prompt deletion');
  } else if (target.closest('[data-prompt-use-preset]')) {
    const checkbox = target.closest('[data-prompt-use-preset]');
    const nextPrompts = promptStore.prompts.map((prompt) => (
      prompt.id === checkbox.dataset.promptUsePreset
        ? { ...prompt, usePreset: checkbox.checked || undefined }
        : prompt
    ));
    if (!persistLibrary(nextPrompts, promptStore.sections)) checkbox.checked = !checkbox.checked;
  } else if (target.closest('[data-prompt-use]')) {
    const id = target.closest('[data-prompt-use]').dataset.promptUse;
    const prompt = promptStore.prompts.find((item) => item.id === id);
    const now = performance.now();
    const previousInsertion = window[insertionGuard];
    if (
      previousInsertion?.promptID === id
        && now - previousInsertion.timestamp < 500
    ) return;
    window[insertionGuard] = { promptID: id, timestamp: now };
    if (!prompt) {
      delete window[insertionGuard];
      return;
    }
    const insertion = insertSavedPrompt(prompt);
    if (insertion && typeof insertion.then === 'function') {
      void insertion.then((inserted) => {
        if (!inserted) delete window[insertionGuard];
      });
    } else if (!insertion) delete window[insertionGuard];
  }
}

function handlePromptInteraction(event) {
  const target = event.target instanceof Element ? event.target : null;
  if (
    event.type === 'keydown'
      && event.key === 'Escape'
      && document.getElementById(dashboardElements.elementIDs.promptDialog)
  ) {
    promptLibraryDialog.handleKeyboard(event, document.getElementById(dashboardElements.elementIDs.promptDialog), close);
    return;
  }
  const dialog = target?.closest(`#${dashboardElements.elementIDs.promptDialog}`);
  if (!dialog || dialog[dialogOwner] !== true) return;
  if (promptReordering.handle(event, target, dialog, persistLibrary, renderDialog)) return;
  if (event.type === 'keydown') {
    if (event.target.matches('[data-prompt-search]') && event.key === 'ArrowDown') {
      event.preventDefault();
      dialog.querySelector('[data-prompt-use]')?.focus();
    } else promptLibraryDialog.handleKeyboard(event, dialog, close);
  }
  else if (
    (event.type === 'input' || event.type === 'search')
      && event.target.matches('[data-prompt-search]')
  ) {
    promptSearchTerm = event.target.value;
    renderDialog({
      searchSelection: {
        start: event.target.selectionStart ?? promptSearchTerm.length,
        end: event.target.selectionEnd ?? promptSearchTerm.length,
      },
    });
  }
  else if (event.type === 'change') {
    if (event.target.matches('[name="hasPreset"]')) {
      const form = event.target.closest('[data-prompt-form]');
      const fields = form?.querySelector('[data-prompt-preset-fields]');
      if (fields) fields.disabled = !event.target.checked;
    }
  }
  else if (event.type === 'submit') handlePromptSubmit(event, target);
  else if (event.type === 'click') handlePromptClick(target);
}

function mount() {
  promptLauncher.mount(open);
  promptInteractionEventTypes.forEach((type) => {
    document.addEventListener(type, handlePromptInteraction, true);
  });
}

function unmount() {
  promptInteractionEventTypes.forEach((type) => {
    document.removeEventListener(type, handlePromptInteraction, true);
  });
  promptLauncher.unmount();
  close({ restoreFocus: false });
}

  return { mount, unmount };
})();
