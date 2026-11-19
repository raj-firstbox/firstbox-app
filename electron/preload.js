// The only computer abilities the Firstbox page gets: save a file into Documents/Firstbox and open that folder.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('firstboxDesktop', {
  saveFile: (name, bytes) => ipcRenderer.invoke('firstbox:save-file', String(name), bytes),
  openFolder: () => ipcRenderer.invoke('firstbox:open-folder'),
  version: () => ipcRenderer.invoke('firstbox:version'),
  platform: process.platform
});
