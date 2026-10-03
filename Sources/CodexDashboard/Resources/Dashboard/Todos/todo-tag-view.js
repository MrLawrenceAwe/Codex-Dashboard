const todoTagView = (() => {
  function tagMarkup(tags, editable = false) {
    if (!tags.length) return '';
    return `<div class="todo-tags" aria-label="To-do tags">${tags.map((tag) => `
      <span class="todo-tag">${domUtils.escapeHTML(tag)}${editable ? `<button type="button" data-todo-tag-remove="${domUtils.escapeHTML(tag)}" aria-label="Remove tag ${domUtils.escapeHTML(tag)}" title="Remove tag ${domUtils.escapeHTML(tag)}">&times;</button>` : ''}</span>
    `).join('')}</div>`;
  }

  function managedTagMarkup(tags, items) {
    if (!tags.length) return '<p class="todo-tag-empty">No tags yet. Create one to organise your to-dos.</p>';
    return tags.map((tag) => {
      const name = domUtils.escapeHTML(tag);
      const count = items.filter((item) => item.tags?.includes(tag)).length;
      return `<div class="todo-managed-tag">
        <div class="todo-managed-tag-details">
          <span class="todo-managed-tag-name" title="${name}">${name}</span>
          <span class="todo-managed-tag-usage">${count} ${count === 1 ? 'to-do' : 'to-dos'}</span>
        </div>
        <div class="todo-managed-tag-actions">
          <button type="button" data-todo-managed-tag-edit="${name}" aria-label="Rename tag ${name}">Rename</button>
          <button type="button" data-todo-managed-tag-remove="${name}" aria-label="Delete tag ${name} from all to-dos">Delete</button>
        </div>
      </div>`;
    }).join('');
  }

  function tagOptions(tags, selectedTag = '') {
    return `<option value="">Choose a tag</option>${tags.map((tag) => (
      `<option value="${domUtils.escapeHTML(tag)}"${tag === selectedTag ? ' selected' : ''}>${domUtils.escapeHTML(tag)}</option>`
    )).join('')}`;
  }

  function tagPickerMarkup(tags) {
    return `<div class="todo-tag-picker">
      <select data-todo-tag aria-label="Tag to attach">${tagOptions(tags)}</select>
    </div>`;
  }

  function filterTagOptions(tags, items, selectedTag = '') {
    const tagCounts = new Map();
    items.forEach((item) => item.tags.forEach((tag) => {
      tagCounts.set(tag, (tagCounts.get(tag) || 0) + 1);
    }));
    return `<option value="">All tags</option>${tags.map((tag) => (
      `<option value="${domUtils.escapeHTML(tag)}"${tag === selectedTag ? ' selected' : ''}>${domUtils.escapeHTML(tag)} (${tagCounts.get(tag) || 0})</option>`
    )).join('')}`;
  }

  function updateTagDraft(tags) {
    const container = document.querySelector('[data-todo-new-tags]');
    if (!container) return;
    container.innerHTML = tagMarkup(tags, true);
  }

  function updateTagOptions(tags) {
    document.querySelectorAll('[data-todo-new-tag], [data-todo-tag]').forEach((select) => {
      select.innerHTML = tagOptions(tags, select.value);
    });
  }

  function updateManagedTags(tags, items = []) {
    const container = document.querySelector('[data-todo-managed-tags]');
    if (!container) return;
    container.innerHTML = managedTagMarkup(tags, items);
    const count = document.querySelector('[data-todo-tag-count]');
    if (count) count.textContent = `${tags.length} of ${todoStore.maximumTags}`;
  }

  function dialogMarkup() {
    return `
      <dialog class="todo-tag-dialog" data-todo-tag-dialog aria-label="Manage tags">
        <header class="todo-tag-dialog-header">
          <div><h2>Manage tags</h2><p>Create and organise tags for your to-dos.</p></div>
          <button type="button" data-todo-tag-dialog-close aria-label="Close tags">&times;</button>
        </header>
        <form data-todo-tag-form class="todo-tag-form">
          <label for="todo-managed-tag-name">Tag name</label>
          <div class="todo-tag-form-fields">
            <input id="todo-managed-tag-name" data-todo-tag-name aria-label="Tag name" placeholder="Enter a tag name" autocomplete="off">
            <button type="submit">Create tag</button>
            <button type="button" class="todo-tag-cancel" data-todo-tag-cancel hidden>Cancel</button>
          </div>
        </form>
        <div class="todo-tag-list-heading"><strong>Your tags</strong><span data-todo-tag-count></span></div>
        <div class="todo-tags" data-todo-managed-tags aria-label="Available tags"></div>
        <p class="todo-tag-dialog-note">Deleting a tag removes it from every to-do.</p>
      </dialog>`;
  }

  return { tagMarkup, managedTagMarkup, tagOptions, tagPickerMarkup, filterTagOptions, updateTagDraft, updateTagOptions, updateManagedTags, dialogMarkup };
})();
