function createPageVisibilityController({ pageID, navigationID, rootClass }) {
  let isOpen = false;

  function applyVisibility() {
    document.getElementById(pageID)?.classList.toggle('is-open', isOpen);
    document.documentElement.classList.toggle(rootClass, isOpen);
    const navigation = document.getElementById(navigationID);
    if (isOpen) navigation?.setAttribute('aria-current', 'page');
    else navigation?.removeAttribute('aria-current');
  }

  function open() {
    if (!document.getElementById(pageID)) return false;
    isOpen = true;
    applyVisibility();
    return true;
  }

  function close() {
    isOpen = false;
    applyVisibility();
  }

  return { open, close, applyVisibility, isOpen: () => isOpen };
}
