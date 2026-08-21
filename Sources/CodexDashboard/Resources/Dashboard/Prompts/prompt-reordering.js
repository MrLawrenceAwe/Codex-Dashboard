const promptReordering = (() => {
  let draggedPromptID;

  function clearIndicators(dialog) {
    dialog?.querySelectorAll('.is-drop-before, .is-drop-after, .is-drop-target').forEach((element) => {
      element.classList.remove('is-drop-before', 'is-drop-after', 'is-drop-target');
    });
  }

  function destinationFor(target) {
    const row = target?.closest('[data-prompt-row-id]');
    const sectionElement = target?.closest('[data-prompt-section]');
    return sectionElement ? {
      row,
      section: sectionElement.dataset.promptSection,
      scopeKey: sectionElement.dataset.promptScopeKey,
      sectionElement,
    } : null;
  }

  function reorder(destination, dropAfter, persist) {
    const movingPrompt = promptStore.prompts.find((prompt) => prompt.id === draggedPromptID);
    if (!movingPrompt || !destination?.section) return false;
    const movingScope = promptStore.normalizeScope(movingPrompt.scope);
    const movingScopeKey = movingScope.type === 'project'
      ? `project:${movingScope.projectPath}`
      : 'global';
    if (movingScopeKey !== destination.scopeKey) return false;
    if (destination.row?.dataset.promptRowId === draggedPromptID) return false;

    const remainingPrompts = promptStore.prompts.filter((prompt) => prompt.id !== draggedPromptID);
    const movedPrompt = { ...movingPrompt, section: promptStore.normalizeSection(destination.section) };
    const targetPromptID = destination.row?.dataset.promptRowId;
    let insertionIndex;
    if (targetPromptID) {
      insertionIndex = remainingPrompts.findIndex((prompt) => prompt.id === targetPromptID);
      if (insertionIndex < 0) insertionIndex = remainingPrompts.length;
      else if (dropAfter) insertionIndex += 1;
    } else {
      insertionIndex = remainingPrompts.reduce((lastIndex, prompt, index) => (
        promptStore.normalizeSection(prompt.section) === movedPrompt.section
          && promptStore.normalizeScope(prompt.scope).type === movingScope.type
          && promptStore.normalizeScope(prompt.scope).projectPath === movingScope.projectPath
          ? index + 1 : lastIndex
      ), remainingPrompts.length);
    }
    remainingPrompts.splice(insertionIndex, 0, movedPrompt);
    if (!persist(remainingPrompts, promptStore.sections)) return false;
    promptStore.prompts = remainingPrompts;
    return true;
  }

  function handle(event, target, dialog, persist, render) {
    if (event.type === 'dragstart') {
      const row = target?.closest('[data-prompt-row-id]');
      if (!row) return false;
      draggedPromptID = row.dataset.promptRowId;
      row.classList.add('is-dragging');
      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', draggedPromptID);
      }
      return true;
    }
    if (!draggedPromptID) return false;
    if (event.type === 'dragend') {
      clearIndicators(dialog);
      dialog?.querySelector('.is-dragging')?.classList.remove('is-dragging');
      draggedPromptID = undefined;
      return true;
    }
    const destination = destinationFor(target);
    if (!destination) return false;
    if (event.type === 'dragover') {
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
      clearIndicators(dialog);
      if (destination.row && destination.row.dataset.promptRowId !== draggedPromptID) {
        const bounds = destination.row.getBoundingClientRect();
        const dropAfter = event.clientY > bounds.top + bounds.height / 2;
        destination.row.classList.add(dropAfter ? 'is-drop-after' : 'is-drop-before');
      } else {
        destination.sectionElement.classList.add('is-drop-target');
      }
      return true;
    }
    if (event.type === 'dragleave') return true;
    if (event.type === 'drop') {
      event.preventDefault();
      const bounds = destination.row?.getBoundingClientRect();
      const dropAfter = Boolean(bounds && event.clientY > bounds.top + bounds.height / 2);
      const moved = reorder(destination, dropAfter, persist);
      dialog?.querySelector('.is-dragging')?.classList.remove('is-dragging');
      clearIndicators(dialog);
      draggedPromptID = undefined;
      if (moved) render();
      return true;
    }
    return false;
  }

  return { handle };
})();
