const composerAdapter = (() => {
  function findComposer() {
    const selectors = [
      'textarea[placeholder="Do anything"]',
      '[contenteditable="true"][data-placeholder="Do anything"]',
      '[contenteditable="true"][role="textbox"]',
      'textarea',
      '[contenteditable="true"]',
    ];
    return selectors.flatMap((selector) => [...document.querySelectorAll(selector)])
      .find((element) => (
        !element.closest(`#${dashboardDOM.elementIDs.promptDialog}`)
          && element.getClientRects().length > 0
      ));
  }

  function insert(content) {
    const composer = findComposer();
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
    if (!selection?.rangeCount || !composer.contains(selection.anchorNode)) {
      const range = document.createRange();
      range.selectNodeContents(composer);
      range.collapse(false);
      selection?.removeAllRanges();
      selection?.addRange(range);
    }
    const needsSeparator = Boolean(composer.textContent && !/\s$/.test(composer.textContent));
    return document.execCommand('insertText', false, `${needsSeparator ? '\n\n' : ''}${content}`);
  }

  return { insert };
})();
