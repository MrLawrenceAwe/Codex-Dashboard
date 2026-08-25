const threadDashboardPage = (() => {
  function mount({ onFilter, onSearch, onLoadMore, onListClick, onAccountAction }) {
    const pageHost = codexHost.pageHost();
    if (!pageHost) return false;
    const page = document.createElement('section');
    page.id = dashboardElements.elementIDs.page;
    page.setAttribute('aria-label', 'Codex Thread Dashboard');
    page.innerHTML = `
      <div class="dashboard-shell">
        <header class="dashboard-header">
          <div>
            <h1>Thread Dashboard</h1>
            <div class="dashboard-summary" data-dashboard-summary aria-label="0 running, 0 unread, 0 changed projects">
              <span><strong data-summary-count="running">0</strong> running</span>
              <span><strong data-summary-count="unread">0</strong> unread</span>
              <span><strong data-summary-count="changed">0</strong> changed</span>
            </div>
          </div>
          <div class="dashboard-account-area">
            <div class="dashboard-account-controls" data-account-controls>
              <label>
                <span class="dashboard-control-label">Codex account</span>
                <select data-account-select aria-label="Active Codex account">
                  <option value="">Current account</option>
                </select>
              </label>
              <button type="button" data-account-save>Save</button>
              <button type="button" data-account-add>Add account</button>
            </div>
            <div class="dashboard-account-usage" data-account-usage hidden></div>
          </div>
        </header>
        <div class="dashboard-notice" data-dashboard-notice role="alert" hidden></div>
        <div class="dashboard-section-header">
          <div class="dashboard-toolbar">
            <label class="dashboard-search" aria-label="Search all threads">${threadMarkup.icon('search')}<input type="search" placeholder="Search by title, project, or message" data-dashboard-search /></label>
            <div class="dashboard-toolbar-group dashboard-filter-group">
              <span class="dashboard-control-label">Show</span>
              <div class="dashboard-filters" aria-label="Filter threads">
                <button type="button" data-filter="all" class="is-active">All <span class="dashboard-filter-count" data-filter-count="all">0</span></button>
                <button type="button" data-filter="running">Running <span class="dashboard-filter-count" data-filter-count="running">0</span></button>
                <button type="button" data-filter="unread">Unread <span class="dashboard-filter-count" data-filter-count="unread">0</span></button>
                <button type="button" data-filter="changedProjects" aria-label="Changed projects"><span class="dashboard-filter-label">Changed projects</span> <span class="dashboard-filter-count" data-filter-count="changedProjects" aria-label="Changed project count">0</span></button>
              </div>
            </div>
          </div>
        </div>
        <main class="dashboard-list" data-thread-list></main>
        <button type="button" class="dashboard-load-more" data-load-more hidden>Load more threads</button>
      </div>`;
    page.querySelectorAll('[data-filter]').forEach((button) => {
      button.addEventListener('click', () => onFilter(button.dataset.filter));
    });
    page.querySelector('[data-dashboard-search]').addEventListener('input', (event) => {
      onSearch(event.target.value);
    });
    page.querySelector('[data-load-more]').addEventListener('click', onLoadMore);
    page.querySelector('[data-thread-list]').addEventListener('click', onListClick);
    page.querySelector('[data-account-select]').addEventListener('change', (event) => {
      if (event.target.value) onAccountAction({ type: 'switch', profileID: event.target.value });
    });
    page.querySelector('[data-account-save]').addEventListener('click', () => {
      const currentName = page.querySelector('[data-account-select] option:checked')?.textContent || '';
      const name = window.prompt('Name this Codex account', currentName === 'Current account' ? '' : currentName);
      if (name?.trim()) onAccountAction({ type: 'save', name: name.trim() });
    });
    page.querySelector('[data-account-add]').addEventListener('click', () => {
      if (window.confirm('Restart Codex signed out so you can add another account?')) {
        onAccountAction({ type: 'add' });
      }
    });
    pageHost.append(page);
    return true;
  }

  return { mount };
})();
