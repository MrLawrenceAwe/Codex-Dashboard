function createPageVisibilityController({ pageID, navigationID, rootClass }) {
  let isOpen = false;

  function restoreOpenState() {
    document.getElementById(pageID)?.classList.toggle('is-open', isOpen);
    document.documentElement.classList.toggle(rootClass, isOpen);
    const navigation = document.getElementById(navigationID);
    if (isOpen) navigation?.setAttribute('aria-current', 'page');
    else navigation?.removeAttribute('aria-current');
  }

  function open() {
    if (!document.getElementById(pageID)) return false;
    isOpen = true;
    restoreOpenState();
    return true;
  }

  function close() {
    isOpen = false;
    restoreOpenState();
  }

  return { open, close, restoreOpenState, isOpen: () => isOpen };
}
