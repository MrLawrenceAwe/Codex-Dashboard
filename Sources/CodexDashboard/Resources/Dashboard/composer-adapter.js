const composerAdapter = (() => {
  function insertIntoEditor(view, content, separateFromExistingContent) {
    const schema = view.state.schema;
    const lines = `${separateFromExistingContent ? '\n' : ''}${content}`.split('\n');
    const paragraphs = lines.map((line) => schema.nodes.paragraph.create(
      null,
      line ? schema.text(line) : null,
    ));
    const fragment = schema.nodes.doc.create(null, paragraphs).content;
    const Slice = view.state.doc.slice(0, 0).constructor;
    const transaction = view.state.tr
      .replaceSelection(new Slice(fragment, 0, 0))
      .scrollIntoView();
    view.focus();
    view.dispatch(transaction);
    return true;
  }

  function insert(content) {
    const composer = codexContracts.composer(dashboardDOM.elementIDs.promptDialog);
    if (!composer) return false;
    composer.focus();
    if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
      const start = composer.selectionStart ?? composer.value.length;
      const end = composer.selectionEnd ?? start;
      const separator = start > 0 && !/\s$/.test(composer.value.slice(0, start)) ? '\n\n' : '';
      const nextValue = `${composer.value.slice(0, start)}${separator}${content}${composer.value.slice(end)}`;
      const valueSetter = Object.getOwnPropertyDescriptor(
        Object.getPrototypeOf(composer),
        'value',
      )?.set;
      valueSetter?.call(composer, nextValue);
      const nextCursor = start + separator.length + content.length;
      composer.setSelectionRange(nextCursor, nextCursor);
      composer.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    }
    const selection = window.getSelection();
    const needsSeparator = Boolean(composer.textContent && !/\s$/.test(composer.textContent));
    const insertedContent = `${needsSeparator ? '\n\n' : ''}${content}`;
    const editorView = codexContracts.composerEditorView(composer);
    if (editorView) {
      return insertIntoEditor(editorView, content, needsSeparator);
    }
    if (!selection?.rangeCount || !composer.contains(selection.anchorNode)) {
      const range = document.createRange();
      range.selectNodeContents(composer);
      range.collapse(false);
      selection?.removeAllRanges();
      selection?.addRange(range);
    }
    const insertion = document.createTextNode(insertedContent);
    const range = selection?.getRangeAt(0);
    if (!range) return false;
    range.deleteContents();
    range.insertNode(insertion);
    range.setStartAfter(insertion);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
    composer.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
  }

  return { insert };
})();
