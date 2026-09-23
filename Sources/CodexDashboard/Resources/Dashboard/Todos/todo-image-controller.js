function createTodoImageController({ isDestroyed, getItems, updateItem }) {
  const maximumBytes = 2 * 1024 * 1024;
  const readers = new Set();
  let draft;

  function setError(message = '') {
    if (isDestroyed()) return;
    const notice = document.querySelector('[data-todo-image-error]');
    if (!notice) return;
    notice.textContent = message;
    notice.hidden = !message;
  }

  function reset() {
    draft = { status: 'empty', image: null, submitWhenReady: false };
    todoListView.updateImageDraft(null);
    const status = document.querySelector('[data-todo-new-image-status]');
    if (status) {
      status.hidden = true;
      status.textContent = '';
    }
  }

  function validationError(file) {
    if (!todoStore.isAcceptedImageType(file?.type)) return 'Choose a JPEG, PNG, GIF, or WebP image.';
    if (file.size > maximumBytes) return 'Images must be 2 MB or smaller.';
    return '';
  }

  function read(file, onLoad, onError = () => {}) {
    setError();
    const error = validationError(file);
    if (error) {
      setError(error);
      return false;
    }
    const reader = new FileReader();
    readers.add(reader);
    reader.addEventListener('loadend', () => readers.delete(reader));
    reader.addEventListener('load', () => {
      if (isDestroyed()) return;
      const image = todoStore.normalizeImage({
        dataURL: reader.result,
        name: file.name,
        type: file.type,
        size: file.size,
      });
      if (!image) {
        setError('Codex could not read that image.');
        onError();
        return;
      }
      onLoad(image);
    });
    reader.addEventListener('error', () => {
      if (isDestroyed()) return;
      setError('Codex could not read that image.');
      onError();
    });
    reader.readAsDataURL(file);
    return true;
  }

  function pastedFile(event) {
    const clipboard = event.clipboardData;
    if (!clipboard) return null;
    return Array.from(clipboard.files || []).find((file) => file.type.startsWith('image/'))
      || Array.from(clipboard.items || [])
        .find((item) => item.kind === 'file' && item.type.startsWith('image/'))?.getAsFile()
      || null;
  }

  function attachToItem(id, file) {
    const item = getItems().find((candidate) => candidate.id === id);
    if (!item || item.completed) return;
    read(file, (image) => updateItem(id, { image }));
  }

  function bind(page) {
    page.addEventListener('paste', (event) => {
      const file = pastedFile(event);
      if (!file) return;
      const row = event.target.closest('[data-todo-id]');
      if (row) {
        event.preventDefault();
        attachToItem(row.dataset.todoId, file);
        return;
      }
      if (!event.target.closest('[data-todo-form]')) return;
      event.preventDefault();
      const error = validationError(file);
      if (error) {
        reset();
        draft.status = 'invalid';
        setError(error);
        return;
      }
      reset();
      draft.status = 'loading';
      const readingDraft = draft;
      const status = page.querySelector('[data-todo-new-image-status]');
      status.textContent = 'Preparing image…';
      status.hidden = false;
      read(file, (image) => {
        if (draft !== readingDraft) return;
        draft.image = image;
        draft.status = 'ready';
        todoListView.updateImageDraft(image);
        status.textContent = 'Image ready to attach when you add this to-do.';
        status.hidden = false;
        if (draft.submitWhenReady) {
          draft.submitWhenReady = false;
          page.querySelector('[data-todo-form]').requestSubmit();
        }
      }, () => {
        if (draft !== readingDraft) return;
        reset();
        draft.status = 'invalid';
        status.hidden = true;
      });
    });
    page.querySelector('[data-todo-new-image-remove]').addEventListener('click', () => {
      reset();
      setError();
      page.querySelector('[data-todo-new-title]').focus();
    });
    page.querySelector('[data-todo-new-image-open]').addEventListener('click', () => {
      if (draft.status === 'ready' && draft.image) todoListView.showImage(draft.image);
    });
  }

  function destroy() {
    readers.forEach((reader) => reader.abort());
    readers.clear();
  }

  reset();
  return { bind, destroy, draft: () => draft, reset, setError };
}
