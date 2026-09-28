function createTaskDashboard({ catalog }) {
  // Snapshots are sorted newest-first on arrival; lookups preserve that order.
  const currentThreads = catalog.currentThreads;
  const storedPreferences = taskDashboardPreferences.loadPreferences();
  let filterMode = storedPreferences.filterMode;
  const pageSize = 10;
  let visibleLimit = pageSize;
  const { collapsedProjectPaths, hiddenChangeIndicatorPaths } = storedPreferences;
  let renderFrame;
  let renderFallbackTimer;
  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.taskPage,
    navigationID: dashboardElements.elementIDs.taskNavButton,
    rootClass: 'codex-dashboard-open',
  });
  let viewNeedsRender = true;
  let commitDialogError = '';
  let markAllReadPending = false;
  let markAllReadError = '';
  let destroyed = false;
  let readConfirmation;
  let presentationState;
  const completionIndicators = createThreadCompletionIndicators({
    findThread: catalog.findThread,
    isThreadUnread: (thread) => presentationState.isThreadUnread(thread),
    onChange: requestRender,
  });
  presentationState = createThreadUnreadState({
    findThread: catalog.findThread,
    isOpen: pageState.isOpen,
    onChange: () => {
      requestRender();
      checkReadConfirmation();
    },
    completionIndicators,
  });
  const { isThreadUnread } = presentationState;
  const isCompletionTickVisible = completionIndicators.isVisible;

  function savePreferences() {
    taskDashboardPreferences.savePreferences({
      filterMode,
      collapsedProjectPaths,
      hiddenChangeIndicatorPaths,
    });
  }

  function deriveViewState() {
    return taskDashboardQuery.summarizeActivity(currentThreads(), isThreadUnread, hiddenChangeIndicatorPaths);
  }

  function syncInterruptedSidebarMarkers() {
    const nextInterruptedThreadIDs = new Set(
      currentThreads()
        .filter((thread) => thread.latestLifecycleEventKind === 'forcedHalt')
        .map((thread) => thread.id),
    );
    document.querySelectorAll('[data-codex-sidebar-interrupted]').forEach((marker) => {
      const threadID = marker.dataset.codexSidebarInterrupted;
      const row = codexUIContracts.threadRow(threadID);
      const title = row?.querySelector('[data-thread-title-trigger]');
      if (!nextInterruptedThreadIDs.has(threadID) || !row?.contains(marker)
          || marker.parentElement !== title?.parentElement) marker.remove();
    });
    nextInterruptedThreadIDs.forEach((threadID) => {
      const row = codexUIContracts.threadRow(threadID);
      if (!row) return;
      let marker = row.querySelector('[data-codex-sidebar-interrupted]');
      if (!marker) {
        const title = row.querySelector('[data-thread-title-trigger]');
        const markerHost = title?.parentElement;
        if (!markerHost) return;
        marker = document.createElement('span');
        marker.setAttribute('data-codex-sidebar-interrupted', threadID);
        marker.textContent = 'Interrupted';
        markerHost.insertBefore(marker, title);
      }
      marker.setAttribute('role', 'status');
      marker.setAttribute('aria-label', 'Interrupted because the usage limit was reached');
      marker.setAttribute('title', 'This task was interrupted because the usage limit was reached');
    });
  }

  function openThread(thread) {
    closeDashboard();
    codexHost.navigateToThread(thread);
  }

  function unconfirmedReadIDs(ids) {
    return ids.filter((id) => {
      const thread = catalog.findThread(id);
      return !thread || thread.isUnread === true || isThreadUnread(thread);
    });
  }

  function checkReadConfirmation() {
    if (!readConfirmation || unconfirmedReadIDs(readConfirmation.ids).length) return;
    readConfirmation.finish([]);
  }

  function waitForReadConfirmation(ids) {
    return new Promise((resolve) => {
      const finish = (remaining) => {
        if (readConfirmation?.finish !== finish) return;
        clearTimeout(readConfirmation.timer);
        readConfirmation = undefined;
        resolve(remaining);
      };
      readConfirmation = {
        ids,
        finish,
        timer: window.setTimeout(() => finish(unconfirmedReadIDs(ids)), 5000),
      };
      checkReadConfirmation();
    });
  }

  async function markAllAsRead() {
    if (markAllReadPending) return;
    const unreadIDs = currentThreads().filter(isThreadUnread).map((thread) => thread.id);
    if (!unreadIDs.length) return;
    markAllReadPending = true;
    markAllReadError = '';
    commitDialogError = '';
    renderDashboard();
    try {
      const { available, failedIDs } = codexHost.markThreadsRead(unreadIDs);
      if (!available) {
        markAllReadError = 'Codex’s read-state action is unavailable. Restart Codex and try again.';
        return;
      }
      presentationState.syncUnread();
      const submittedIDs = unreadIDs.filter((id) => !failedIDs.includes(id));
      const unconfirmedIDs = submittedIDs.length
        ? await waitForReadConfirmation(submittedIDs) : [];
      const failed = failedIDs.length + unconfirmedIDs.length;
      markAllReadError = failed
        ? `Codex could not confirm ${failed} ${failed === 1 ? 'task' : 'tasks'} as read. Try again.`
        : '';
    } catch {
      markAllReadError = 'Codex’s read-state action failed. Try again.';
    } finally {
      markAllReadPending = false;
      if (!destroyed) renderDashboard();
    }
  }

  async function openCommitDialogForProject(projectPath) {
    commitDialogError = '';
    const thread = currentThreads().find(
      (item) => item.runState !== 'running' && String(item.projectPath).trim() === projectPath,
    );
    if (!thread) {
      commitDialogError = 'No idle task is available for this project.';
      renderDashboard();
      return;
    }
    closeDashboard();
    const result = await codexHost.openCommitDialog(thread);
    if (result.opened) return;
    commitDialogError = result.reason;
    dashboardNavigation.openTasks();
    renderDashboard();
  }

  function renderDashboard() {
    cancelScheduledRender();
    const state = deriveViewState();
    const rendered = taskDashboardView.render({
      threads: currentThreads(),
      filterMode,
      visibleItemLimit: visibleLimit,
      collapsedProjectPaths,
      hiddenChangeIndicatorPaths,
      commitDialogError,
      markAllReadPending,
      markAllReadError,
      isThreadUnread,
      isCompletionTickVisible,
      state,
    });
    if (rendered) viewNeedsRender = false;
  }

  function cancelScheduledRender() {
    if (renderFrame !== undefined) cancelAnimationFrame(renderFrame);
    if (renderFallbackTimer !== undefined) clearTimeout(renderFallbackTimer);
    renderFrame = undefined;
    renderFallbackTimer = undefined;
  }

  function scheduleRender() {
    if (renderFrame !== undefined) return;
    renderFrame = requestAnimationFrame(() => {
      renderFrame = undefined;
      renderDashboard();
    });
    // WebKit may heavily throttle animation frames for an occluded renderer.
    // Keep state updates timely there without affecting the normal visible-frame
    // path, which remains coalesced through requestAnimationFrame.
    renderFallbackTimer = window.setTimeout(() => {
      if (renderFrame === undefined) return;
      cancelAnimationFrame(renderFrame);
      renderFrame = undefined;
      renderFallbackTimer = undefined;
      renderDashboard();
    }, 100);
  }

  function requestRender() {
    if (pageState.isOpen()) {
      scheduleRender();
      return;
    }
    viewNeedsRender = true;
    taskDashboardView.updateSidebarStatus(deriveViewState());
  }

  function mountTaskNavigationButton() {
    if (document.getElementById(dashboardElements.elementIDs.taskNavButton)) return true;
    if (!mountDashboardNavigationButton({
      id: dashboardElements.elementIDs.taskNavButton,
      label: 'Task Dashboard',
      markup: `
      <div class="dashboard-nav-copy">
        <span class="dashboard-nav-icon">${dashboardIcons.render('threads')}</span>
        <span class="dashboard-nav-label">Task Dashboard</span>
      </div>
      <div class="dashboard-nav-status">
        <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="0 running tasks" title="0 running tasks" hidden><span data-navigation-running-count aria-hidden="true">0</span></span>
        <span class="dashboard-nav-changes" data-navigation-changes role="status" aria-label="0 projects with uncommitted changes" title="0 projects with uncommitted changes" hidden>${dashboardIcons.render('gitChanges')}</span>
        <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread tasks" hidden>0</strong>
      </div>`,
    })) return false;
    taskDashboardView.updateSidebarStatus(deriveViewState());
    pageState.applyVisibility();
    return true;
  }

  function mountTaskDashboardPage() {
    if (document.getElementById(dashboardElements.elementIDs.taskPage)) return true;
    viewNeedsRender = true;
    const mounted = taskDashboardPage.mount({
      onMarkAllRead: () => { void markAllAsRead(); },
      onFilter: (nextFilterMode) => {
        if (filterMode === nextFilterMode) return;
        filterMode = nextFilterMode;
        visibleLimit = pageSize;
        savePreferences();
        renderDashboard();
      },
      onLoadMore: () => {
        visibleLimit += pageSize;
        renderDashboard();
      },
      onListClick: (event) => {
        const projectIndicators = event.target.closest('[data-project-indicators]');
        if (projectIndicators) {
          event.preventDefault();
          const projectPath = projectIndicators.dataset.projectIndicators;
          if (hiddenChangeIndicatorPaths.has(projectPath)) hiddenChangeIndicatorPaths.delete(projectPath);
          else hiddenChangeIndicatorPaths.add(projectPath);
          commitDialogError = '';
          savePreferences();
          renderDashboard();
          return;
        }
        const projectCommit = event.target.closest('[data-project-commit]');
        if (projectCommit) {
          event.preventDefault();
          void openCommitDialogForProject(projectCommit.dataset.projectCommit);
          return;
        }
        const projectToggle = event.target.closest('[data-project-toggle]');
        if (projectToggle) {
          const projectPath = projectToggle.dataset.projectToggle;
          if (collapsedProjectPaths.has(projectPath)) collapsedProjectPaths.delete(projectPath);
          else collapsedProjectPaths.add(projectPath);
          savePreferences();
          renderDashboard();
          return;
        }
        openThreadFromEvent(event);
      },
    });
    if (mounted) pageState.applyVisibility();
    return mounted;
  }

  function openThreadFromEvent(event) {
    const eventTarget = event.target instanceof Element ? event.target : null;
    const target = eventTarget?.closest('[data-open-thread]');
    if (!target) return;
    const thread = catalog.findThread(target.dataset.openThread);
    if (thread) openThread(thread);
  }

  function openDashboard() {
    if (!pageState.open()) return;
    if (presentationState.syncUnread()) viewNeedsRender = true;
    if (viewNeedsRender) renderDashboard();
    else taskDashboardView.updateSidebarStatus(deriveViewState());
    presentationState.scheduleUnreadSync(1500);
  }

  function closeDashboard() {
    pageState.close();
    presentationState.scheduleUnreadSync();
  }

  function applyThreads() {
    syncInterruptedSidebarMarkers();
    presentationState.applyThreads(currentThreads());
    checkReadConfirmation();
    // A native refresh can update the catalog, unread state, and Git state in a
    // short burst. Keep the renderer responsive by applying only the latest
    // snapshot in the next frame instead of rebuilding the task list for each
    // delivery.
    if (pageState.isOpen()) {
      viewNeedsRender = true;
      scheduleRender();
    } else {
      requestRender();
    }
    return true;
  }

  function destroy() {
    destroyed = true;
    readConfirmation?.finish(readConfirmation.ids);
    pageState.close();
    cancelScheduledRender();
    presentationState.destroy();
    completionIndicators.destroy();
    document.querySelectorAll('[data-codex-sidebar-interrupted]').forEach((marker) => marker.remove());
    viewNeedsRender = true;
  }


  return {
    mountNavigation: mountTaskNavigationButton,
    mountPage: mountTaskDashboardPage,
    applyVisibility: pageState.applyVisibility,
    startMonitoring: presentationState.startMonitoring,
    requestRender,
    syncInterruptedSidebarMarkers,
    syncUnread: presentationState.syncUnread,
    destroy,
    open: openDashboard,
    close: closeDashboard,
    isOpen: pageState.isOpen,
    applyThreads,
  };
}
