function clearPromptDropIndicators(dialog) {
  dialog?.querySelectorAll('.is-drop-before, .is-drop-after, .is-drop-target').forEach((element) => {
    element.classList.remove('is-drop-before', 'is-drop-after', 'is-drop-target');
  });
}

function promptDropDestination(target) {
  const row = target?.closest('[data-prompt-row-id]');
  const sectionElement = target?.closest('[data-prompt-section]');
  return sectionElement ? {
    row,
    section: sectionElement.dataset.promptSection,
    sectionElement,
  } : null;
}

function reorderPrompt(destination, dropAfter) {
  const movingPrompt = prompts.find((prompt) => prompt.id === draggedPromptID);
  if (!movingPrompt || !destination?.section) return false;
  if (destination.row?.dataset.promptRowId === draggedPromptID) return false;

  const remainingPrompts = prompts.filter((prompt) => prompt.id !== draggedPromptID);
  const movedPrompt = { ...movingPrompt, section: normalizePromptSection(destination.section) };
  const targetPromptID = destination.row?.dataset.promptRowId;
  let insertionIndex;
  if (targetPromptID) {
    insertionIndex = remainingPrompts.findIndex((prompt) => prompt.id === targetPromptID);
    if (insertionIndex < 0) insertionIndex = remainingPrompts.length;
    else if (dropAfter) insertionIndex += 1;
  } else {
    insertionIndex = remainingPrompts.reduce((lastIndex, prompt, index) => (
      normalizePromptSection(prompt.section) === movedPrompt.section ? index + 1 : lastIndex
    ), remainingPrompts.length);
  }
  remainingPrompts.splice(insertionIndex, 0, movedPrompt);
  if (!storePrompts(remainingPrompts)) return false;
  prompts = remainingPrompts;
  return true;
}

function handlePromptDrag(event, target, dialog) {
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
    clearPromptDropIndicators(dialog);
    dialog?.querySelector('.is-dragging')?.classList.remove('is-dragging');
    draggedPromptID = undefined;
    return true;
  }
  const destination = promptDropDestination(target);
  if (!destination) return false;
  if (event.type === 'dragover') {
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
    clearPromptDropIndicators(dialog);
    if (destination.row && destination.row.dataset.promptRowId !== draggedPromptID) {
      const dropAfter = event.clientY > destination.row.getBoundingClientRect().top
        + destination.row.getBoundingClientRect().height / 2;
      destination.row.classList.add(dropAfter ? 'is-drop-after' : 'is-drop-before');
    } else {
      destination.sectionElement.classList.add('is-drop-target');
    }
    return true;
  }
  if (event.type === 'dragleave') return true;
  if (event.type === 'drop') {
    event.preventDefault();
    const dropAfter = Boolean(
      destination.row
        && event.clientY > destination.row.getBoundingClientRect().top
          + destination.row.getBoundingClientRect().height / 2
    );
    const moved = reorderPrompt(destination, dropAfter);
    draggedPromptID = undefined;
    if (moved) renderPromptLibrary();
    else clearPromptDropIndicators(dialog);
    return true;
  }
  return false;
}
