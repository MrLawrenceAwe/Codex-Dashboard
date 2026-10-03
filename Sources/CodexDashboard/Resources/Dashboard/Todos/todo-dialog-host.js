const todoDialogHost = (() => {
  function ensureDialogHost() {
    const existing = document.getElementById(dashboardElements.elementIDs.todoDialogHost);
    if (existing) return existing;
    const dialogHost = document.createElement('div');
    dialogHost.id = dashboardElements.elementIDs.todoDialogHost;
    dialogHost.innerHTML = `
      ${todoImageView.dialogMarkup()}
      ${todoTagView.dialogMarkup()}`;
    document.body.append(dialogHost);
    const imageDialog = dialogHost.querySelector('[data-todo-image-dialog]');
    imageDialog.querySelector('[data-todo-image-dialog-close]').addEventListener('click', () => imageDialog.close());
    imageDialog.addEventListener('click', (event) => {
      if (event.target === imageDialog) imageDialog.close();
    });
    return dialogHost;
  }

  return { ensure: ensureDialogHost };
})();
