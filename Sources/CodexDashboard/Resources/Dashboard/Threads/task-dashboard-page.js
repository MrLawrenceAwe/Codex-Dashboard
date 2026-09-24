const taskDashboardPage = (() => {
  function mount({ onFilter, onLoadMore, onListClick }) {
    const pageHost = codexHost.pageHost();
    if (!pageHost) return false;
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.taskPage;
    page.setAttribute('aria-label', 'Codex Task Dashboard');
    page.innerHTML = `
      <div class="dashboard-shell">
        <header class="dashboard-header">
          <h1>Task Dashboard</h1>
        </header>
        <div class="dashboard-notice" data-commit-notice role="alert" hidden></div>
        <div class="dashboard-section-header">
          <div class="dashboard-toolbar">
            <div class="dashboard-toolbar-group dashboard-filter-group">
              <span class="dashboard-control-label">Show</span>
              <div class="dashboard-filters" aria-label="Filter tasks">
                <button type="button" data-filter="recent" class="is-active">Home</button>
                <button type="button" data-filter="unread">Unread <span class="dashboard-filter-count" data-filter-count="unread">0</span></button>
                <button type="button" data-filter="changedProjects" aria-label="Changed projects"><span class="dashboard-filter-label">Changed projects</span> <span class="dashboard-filter-count" data-filter-count="changedProjects" aria-label="Changed project count">0</span></button>
              </div>
            </div>
          </div>
        </div>
        <main class="dashboard-list" data-thread-list></main>
        <button type="button" class="dashboard-load-more" data-load-more hidden>Load more</button>
      </div>`;
    page.querySelectorAll('[data-filter]').forEach((button) => {
      button.addEventListener('click', () => onFilter(button.dataset.filter));
    });
    page.querySelector('[data-load-more]').addEventListener('click', onLoadMore);
    page.querySelector('[data-thread-list]').addEventListener('click', onListClick);
    pageHost.append(page);
    return true;
  }

  return { mount };
})();
