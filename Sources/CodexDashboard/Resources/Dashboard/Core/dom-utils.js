const domUtils = (() => {
  function escapeHTML(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
    })[character]);
  }

  function isVisible(element) {
    if (!element || element.getClientRects().length === 0) return false;
    const style = getComputedStyle(element);
    return style.display !== 'none' && style.visibility !== 'hidden';
  }

  function isLightSurface(surface) {
    let element = surface.closest('[role="menu"]') || surface;
    while (element) {
      const match = getComputedStyle(element).backgroundColor.match(
        /^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/,
      );
      if (match && (match[4] === undefined || Number(match[4]) > 0)) {
        const [red, green, blue] = match.slice(1, 4).map(Number);
        // A surface is light when its perceived brightness is above the
        // midpoint. Reading the rendered host avoids relying on private CSS
        // class names that can change between Codex releases.
        return (red * 0.2126 + green * 0.7152 + blue * 0.0722) > 128;
      }
      element = element.parentElement;
    }
    return !matchMedia('(prefers-color-scheme: dark)').matches;
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

  return { delay, escapeHTML, isLightSurface, isVisible, waitFor };
})();
