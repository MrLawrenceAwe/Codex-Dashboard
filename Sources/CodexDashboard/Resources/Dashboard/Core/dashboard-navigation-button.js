function mountDashboardNavigationButton({ id, label, markup, afterID }) {
  if (document.getElementById(id)) return true;
  const precedingButton = afterID && document.getElementById(afterID);
  const insertionPoint = precedingButton
    ? { element: precedingButton, insertAfter: true }
    : codexHost.navigationInsertionPoint();
  if (!insertionPoint?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = id;
  button.type = 'button';
  button.className = insertionPoint.element.className;
  button.setAttribute('aria-label', label);
  button.innerHTML = markup;
  if (insertionPoint.insertAfter) insertionPoint.element.after(button);
  else insertionPoint.element.before(button);
  return true;
}
