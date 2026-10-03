const todoImageView = (() => {
  function imageMarkup(item) {
    if (!item.image?.dataURL) return '';
    const name = domUtils.escapeHTML(item.image.name);
    return `
      <div class="todo-image">
        <button type="button" class="todo-image-preview" data-todo-image-preview aria-label="View image: ${name}" title="View image">
          <img src="${domUtils.escapeHTML(item.image.dataURL)}" alt="${name}">
        </button>
        <span class="todo-image-name" title="${name}">${name}</span>
      </div>`;
  }

  function showHydratedImages(items) {
    const page = document.getElementById(dashboardElements.elementIDs.todoPage);
    if (!page) return;
    for (const item of items) {
      const row = [...page.querySelectorAll('[data-todo-id]')]
        .find((candidate) => candidate.dataset.todoId === item.id);
      const copy = row?.querySelector('.todo-item-copy');
      if (!copy || copy.querySelector('.todo-image')) continue;
      const actions = copy.querySelector('.todo-image-actions');
      if (actions) actions.insertAdjacentHTML('beforebegin', imageMarkup(item));
      else copy.insertAdjacentHTML('beforeend', imageMarkup(item));
    }
  }

  function updateImageDraft(image) {
    const preview = document.querySelector('[data-todo-new-image-preview]');
    if (!preview) return;
    const previewImage = preview.querySelector('img');
    const form = preview.closest('[data-todo-form]');
    preview.hidden = !image;
    previewImage.src = image?.dataURL || '';
    previewImage.alt = image?.name || '';
    preview.title = image?.name || '';
    const previewButton = preview.querySelector('[data-todo-new-image-open]');
    previewButton?.setAttribute('aria-label', image ? `Preview pasted image: ${image.name}` : 'Preview pasted image');
    previewButton?.setAttribute('title', image ? `Preview ${image.name}` : 'Preview pasted image');
    form?.classList.toggle('has-image', Boolean(image));
  }

  function showImage(image) {
    const dialog = document.querySelector('[data-todo-image-dialog]');
    if (!dialog) return;
    const preview = dialog.querySelector('img');
    preview.src = image.dataURL;
    preview.alt = image.name;
    dialog.showModal();
  }

  function dialogMarkup() {
    return `
      <dialog class="todo-image-dialog" data-todo-image-dialog aria-label="Image preview">
        <button type="button" data-todo-image-dialog-close aria-label="Close image preview">&times;</button>
        <img alt="">
      </dialog>`;
  }

  return { imageMarkup, showHydratedImages, updateImageDraft, showImage, dialogMarkup };
})();
