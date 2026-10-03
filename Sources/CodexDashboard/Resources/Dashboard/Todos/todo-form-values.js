const todoFormValues = (() => {
  function readPreset(toggle, fields) {
    if (!toggle.checked) return null;
    return composerPresets.normalize({
      model: fields.querySelector('[data-todo-new-preset-model], [data-todo-item-preset-model]').value,
      reasoningEffort: fields.querySelector('[data-todo-new-preset-effort], [data-todo-item-preset-effort]').value,
      speed: fields.querySelector('[data-todo-new-preset-speed], [data-todo-item-preset-speed]').value,
    }) || null;
  }

  return { readPreset };
})();
