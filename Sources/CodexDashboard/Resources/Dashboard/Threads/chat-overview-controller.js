function createChatOverview({ catalog }) {
  // Snapshots are sorted newest-first on arrival; lookups preserve that order.
  const currentThreads = catalog.currentThreads;
  const storedPreferences = chatOverviewPreferences.loadPreferences();
  let filterMode = storedPreferences.filterMode;
  const pageSize = 10;
  let visibleLimit = pageSize;
  const { collapsedProjectPaths, hiddenChangeIndicatorPaths } = storedPreferences;
  let renderFrame;
  let renderFallbackTimer;
  const pageState = createPageVisibilityController({
    pageID: dashboardElements.elementIDs.chatOverviewPage,
    navigationID: dashboardElements.elementIDs.chatOverviewNavButton,
    rootClass: 'codex-dashboard-open',
  });
  let viewNeedsRender = true;
  let commitDialogError = '';
  let markAllReadPending = false;
  let markAllReadError = '';
  let destroyed = false;
  let readConfirmation;
  let unreadState;
  const completionIndicators = createThreadCompletionIndicators({
    findThread: catalog.findThread,
    isThreadUnread: (thread) => unreadState.isThreadUnread(thread),
    onChange: requestRender,
  });
  unreadState = createThreadUnreadState({
    findThread: catalog.findThread,
    isOpen: pageState.isOpen,
    onChange: () => {
      requestRender();
      checkReadConfirmation();
    },
    completionIndicators,
  });
  const { isThreadUnread } = unreadState;
  const isCompletionTickVisible = completionIndicators.isVisible;

  function savePreferences() {
    chatOverviewPreferences.savePreferences({
      filterMode,
      collapsedProjectPaths,
      hiddenChangeIndicatorPaths,
    });
  }

  function deriveViewState() {
    return chatOverviewQuery.summarizeActivity(currentThreads(), isThreadUnread, hiddenChangeIndicatorPaths);
  }

  function openThread(thread) {
    closeChatOverview();
    codexHost.navigateToThread(thread);
  }

  function unconfirmedReadIDs(ids) {
    return ids.filter((id) => {
      const thread = catalog.findThread(id);
      return !thread || isThreadUnread(thread);
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
    renderChatOverview();
    try {
      const { available, failedIDs } = codexHost.markThreadsRead(unreadIDs);
      if (!available) {
        markAllReadError = 'Codex’s read-state action is unavailable. Restart Codex and try again.';
        return;
      }
      const submittedIDs = unreadIDs.filter((id) => !failedIDs.includes(id));
      unreadState.markReadRequested(submittedIDs);
      unreadState.syncUnread();
      const unconfirmedIDs = submittedIDs.length
        ? await waitForReadConfirmation(submittedIDs) : [];
      const failed = failedIDs.length + unconfirmedIDs.length;
      markAllReadError = failed
        ? `Codex could not confirm ${failed} ${failed === 1 ? 'chat' : 'chats'} as read. Try again.`
        : '';
    } catch {
      markAllReadError = 'Codex’s read-state action failed. Try again.';
    } finally {
      markAllReadPending = false;
      if (!destroyed) renderChatOverview();
    }
  }

  async function openCommitDialogForProject(projectPath) {
    commitDialogError = '';
    const thread = currentThreads().find(
      (item) => item.runState !== 'running' && String(item.projectGroupPath || '').trim() === projectPath,
    );
    if (!thread) {
      commitDialogError = 'No idle chat is available for this project.';
      renderChatOverview();
      return;
    }
    closeChatOverview();
    const result = await codexHost.openCommitDialog(thread);
    if (result.opened || result.cancelled) return;
    commitDialogError = result.reason;
    dashboardNavigation.openPage(chatOverview);
    renderChatOverview();
  }

  function renderChatOverview() {
    cancelScheduledRender();
    const state = deriveViewState();
    if (state.unreadCount === 0) markAllReadError = '';
    const rendered = chatOverviewView.render({
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
      renderChatOverview();
    });
    // WebKit may heavily throttle animation frames for an occluded renderer.
    // Keep state updates timely there without affecting the normal visible-frame
    // path, which remains coalesced through requestAnimationFrame.
    renderFallbackTimer = window.setTimeout(() => {
      if (renderFrame === undefined) return;
      cancelAnimationFrame(renderFrame);
      renderFrame = undefined;
      renderFallbackTimer = undefined;
      renderChatOverview();
    }, 100);
  }

  function requestRender() {
    if (pageState.isOpen()) {
      scheduleRender();
      return;
    }
    viewNeedsRender = true;
    chatOverviewView.updateSidebarStatus(deriveViewState());
  }

  function mountChatOverviewNavigationButton() {
    if (document.getElementById(dashboardElements.elementIDs.chatOverviewNavButton)) return true;
    if (!mountDashboardNavigationButton({
      id: dashboardElements.elementIDs.chatOverviewNavButton,
      label: 'Chat overview',
      markup: `
      <div class="dashboard-nav-copy">
        <span class="dashboard-nav-icon">${dashboardIcons.render('threads')}</span>
        <span class="dashboard-nav-label">Chat overview</span>
      </div>
      <div class="dashboard-nav-status">
        <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="0 running chats" title="0 running chats" hidden><span data-navigation-running-count aria-hidden="true">0</span></span>
        <span class="dashboard-nav-changes" data-navigation-changes role="status" aria-label="0 projects with uncommitted changes or unpushed commits" title="0 projects with uncommitted changes or unpushed commits" hidden>${dashboardIcons.render('gitChanges')}</span>
        <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread chats" hidden>0</strong>
      </div>`,
    })) return false;
    chatOverviewView.updateSidebarStatus(deriveViewState());
    pageState.applyVisibility();
    return true;
  }

  function mountChatOverviewPage() {
    if (document.getElementById(dashboardElements.elementIDs.chatOverviewPage)) return true;
    viewNeedsRender = true;
    const mounted = chatOverviewPage.mount({
      onMarkAllRead: () => { void markAllAsRead(); },
      onFilter: (nextFilterMode) => {
        if (filterMode === nextFilterMode) return;
        filterMode = nextFilterMode;
        visibleLimit = pageSize;
        savePreferences();
        renderChatOverview();
      },
      onLoadMore: () => {
        visibleLimit += pageSize;
        renderChatOverview();
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
          renderChatOverview();
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
          renderChatOverview();
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

  function openChatOverview() {
    if (!pageState.open()) return;
    if (unreadState.syncUnread()) viewNeedsRender = true;
    if (viewNeedsRender) renderChatOverview();
    else chatOverviewView.updateSidebarStatus(deriveViewState());
    unreadState.scheduleUnreadSync(1500);
  }

  function closeChatOverview() {
    pageState.close();
    unreadState.scheduleUnreadSync();
  }

  function applyThreads() {
    threadInterruptionIndicators.applyThreads(currentThreads());
    unreadState.applyThreads(currentThreads());
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
    unreadState.destroy();
    completionIndicators.destroy();
    threadInterruptionIndicators.destroy();
    viewNeedsRender = true;
  }


  return {
    mountNavigation: mountChatOverviewNavigationButton,
    mountPage: mountChatOverviewPage,
    applyVisibility: pageState.applyVisibility,
    startMonitoring: unreadState.startMonitoring,
    requestRender,
    syncInterruptedSidebarMarkers: () => threadInterruptionIndicators.applyThreads(currentThreads()),
    syncUnread: unreadState.syncUnread,
    destroy,
    open: openChatOverview,
    close: closeChatOverview,
    isOpen: pageState.isOpen,
    applyThreads,
  };
}
