const usageResetNotice = (() => {
  let blockage;
  let countdownTimer;
  const countdownID = 'codex-usage-blockage';
  let countdownCollapsed = false;
  let countdownPosition = null;
  let countdownResizeHandler;

  function positionCountdown(notice, left, top) {
    const rect = notice.getBoundingClientRect();
    countdownPosition = {
      left: Math.max(12, Math.min(left, innerWidth - rect.width - 12)),
      top: Math.max(12, Math.min(top, innerHeight - rect.height - 12)),
    };
    notice.style.right = 'auto';
    notice.style.left = `${countdownPosition.left}px`;
    notice.style.top = `${countdownPosition.top}px`;
  }

  function removeCountdown() {
    if (countdownResizeHandler) window.removeEventListener('resize', countdownResizeHandler);
    countdownResizeHandler = undefined;
    document.getElementById(countdownID)?.remove();
    if (countdownTimer !== undefined) clearInterval(countdownTimer);
    countdownTimer = undefined;
  }

  function setupCountdown(notice) {
    notice.innerHTML = `<header class="codex-usage-reset-header" title="Drag to move">
      <strong data-reset-title></strong>
      <button type="button" data-reset-toggle aria-controls="codex-usage-reset-details"></button>
      </header><div data-reset-countdown role="timer" aria-live="off"></div>
      <div id="codex-usage-reset-details"><div data-reset-date></div>
      <div data-reset-status></div></div>`;
    const toggle = notice.querySelector('[data-reset-toggle]');
    toggle.addEventListener('click', () => {
      countdownCollapsed = !countdownCollapsed;
      renderCountdown();
    });
    const header = notice.querySelector('header');
    let drag = null;
    header.addEventListener('pointerdown', (event) => {
      if (event.button !== 0 || event.target.closest('button')) return;
      const rect = notice.getBoundingClientRect();
      drag = { pointerID: event.pointerId, x: event.clientX - rect.left, y: event.clientY - rect.top };
      header.setPointerCapture(event.pointerId);
      notice.classList.add('is-dragging');
      event.preventDefault();
    });
    header.addEventListener('pointermove', (event) => {
      if (drag?.pointerID !== event.pointerId) return;
      positionCountdown(notice, event.clientX - drag.x, event.clientY - drag.y);
    });
    const endDrag = () => {
      drag = null;
      notice.classList.remove('is-dragging');
    };
    header.addEventListener('pointerup', endDrag);
    header.addEventListener('pointercancel', endDrag);
    header.addEventListener('lostpointercapture', endDrag);
    countdownResizeHandler = () => {
      const rect = notice.getBoundingClientRect();
      positionCountdown(notice, rect.left, rect.top);
    };
    window.addEventListener('resize', countdownResizeHandler);
  }

  function formatResetCountdown(deadline) {
    const seconds = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const remainder = seconds % 60;
    return [days ? `${days}d` : '', hours ? `${hours}h` : '',
      minutes ? `${minutes}m` : '', `${remainder}s`].filter(Boolean).join(' ');
  }

  function renderCountdown() {
    if (!blockage?.windows.length) {
      removeCountdown();
      return;
    }
    let notice = document.getElementById(countdownID);
    if (!notice) {
      notice = document.createElement('section');
      notice.id = countdownID;
      notice.setAttribute('aria-label', 'Codex usage reset countdown');
      document.body.append(notice);
      setupCountdown(notice);
    }
    notice.classList.toggle('is-light', domUtils.isLightSurface(document.querySelector('main') || document.body));
    const windows = blockage.windows;
    const deadlines = windows.map((window) => window.resetsAtMilliseconds);
    const hasAllDeadlines = deadlines.every((deadline) => Number.isFinite(deadline));
    const latestReset = hasAllDeadlines ? Math.max(...deadlines) : null;
    const resetDue = latestReset !== null && latestReset <= Date.now();
    const title = resetDue ? 'Reset due — awaiting usage update'
      : blockage.isStale ? 'Last known allowance depleted' : 'Codex allowance depleted';
    const countdown = latestReset === null ? 'Reset time unavailable'
      : resetDue ? 'Awaiting usage update…' : `Available in ${formatResetCountdown(latestReset)}`;
    const absolute = latestReset !== null && !resetDue
      ? `Reset: ${new Date(latestReset).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })}` : '';
    // Update text in place so the ticking clock never steals focus from the collapse control.
    notice.classList.toggle('is-collapsed', countdownCollapsed);
    notice.querySelector('#codex-usage-reset-details').hidden = countdownCollapsed;
    const toggle = notice.querySelector('[data-reset-toggle]');
    toggle.setAttribute('aria-expanded', String(!countdownCollapsed));
    toggle.setAttribute('aria-label', countdownCollapsed ? 'Expand usage notice' : 'Collapse usage notice');
    toggle.title = countdownCollapsed ? 'Expand' : 'Collapse';
    toggle.innerHTML = countdownCollapsed
      ? '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="m4 6 4 4 4-4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>'
      : '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="m4 10 4-4 4 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    notice.querySelector('[data-reset-title]').textContent = title;
    notice.querySelector('[data-reset-countdown]').textContent = countdown;
    notice.querySelector('[data-reset-date]').textContent = absolute;
    notice.querySelector('[data-reset-date]').hidden = !absolute;
    const status = notice.querySelector('[data-reset-status]');
    status.textContent = blockage.isStale ? 'Usage may be stale.' : '';
    status.hidden = !blockage.isStale;
    const position = countdownPosition || notice.getBoundingClientRect();
    positionCountdown(notice, position.left, position.top);
    if (countdownTimer === undefined) countdownTimer = setInterval(renderCountdown, 1000);
  }

  function applySnapshot(nextBlockage) {
    blockage = nextBlockage;
    renderCountdown();
  }

  return { applySnapshot, destroy: removeCountdown };
})();
