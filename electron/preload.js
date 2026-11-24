// The only computer abilities the Firstbox page gets: save a file into the Firstbox save folder, open it, and choose which folder that is.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('firstboxDesktop', {
  saveFile: (name, bytes) => ipcRenderer.invoke('firstbox:save-file', String(name), bytes),
  openFolder: () => ipcRenderer.invoke('firstbox:open-folder'),
  getSaveFolder: () => ipcRenderer.invoke('firstbox:get-save-folder'),        // {folder, custom, missing, wanted}
  chooseSaveFolder: () => ipcRenderer.invoke('firstbox:choose-save-folder'),  // opens the Mac/Windows folder picker
  resetSaveFolder: () => ipcRenderer.invoke('firstbox:reset-save-folder'),
  version: () => ipcRenderer.invoke('firstbox:version'),
  platform: process.platform,
  confirmsUnload: true   // main.js shows the unsaved-changes question on close
});
