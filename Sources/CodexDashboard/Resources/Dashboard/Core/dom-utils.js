const domUtils = (() => {
  function isVisible(element) {
    if (!element || element.getClientRects().length === 0) return false;
    const style = getComputedStyle(element);
    return style.display !== 'none' && style.visibility !== 'hidden';
  }

  function delay(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
  }

  async function waitFor(value, { timeout = 3000, interval = 50 } = {}) {
    const deadline = performance.now() + timeout;
    while (performance.now() < deadline) {
      const result = value();
      if (result) return result;
      await delay(interval);
    }
    return null;
  }

  return { delay, isVisible, waitFor };
})();
