const todoQuery = (() => {
  function visibleItems(items, filterMode, projectFilter, tagFilter) {
    return items.filter((item) => {
      const matchesStatus = filterMode === 'all'
        || (filterMode === 'open' && !item.completed)
        || (filterMode === 'completed' && item.completed);
      const matchesProject = !projectFilter
        || (projectFilter === '__none__' && !item.project)
        || item.project?.id === projectFilter;
      const matchesTag = !tagFilter || item.tags.includes(tagFilter);
      return matchesStatus && matchesProject && matchesTag;
    });
  }

  return { visibleItems };
})();
