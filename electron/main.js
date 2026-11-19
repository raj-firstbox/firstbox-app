// Firstbox desktop app (Mac and Windows).
// Opens the Firstbox page in its own window. If the online copy of the page is reachable it loads that,
// so changes reach everyone without reinstalling; otherwise it uses the copy built into the app.
// PDFs and other files the page saves go to Documents/Firstbox on this computer.
const { app, BrowserWindow, ipcMain, shell, dialog, Menu } = require('electron');
const path = require('path');
const fs = require('fs');

const CONFIG = (() => { try { return require('./app-config.json'); } catch (e) { return {}; } })();
const LOCAL_INDEX = path.join(__dirname, '..', 'web', 'index.html');
const ONLINE_URL = CONFIG.uiUrl || '';
const ONLINE_ORIGIN = ONLINE_URL ? new URL(ONLINE_URL).origin : null;

let win = null;

function firstboxFolder(sub) {
  const dir = path.join(app.getPath('documents'), 'Firstbox', sub || '');
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}
function safeName(name) {
  return String(name || 'file').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 150) || 'file';
}
function isTrusted(url) {
  if (!url) return false;
  if (url.startsWith('file://')) return true;
  try { return !!ONLINE_ORIGIN && new URL(url).origin === ONLINE_ORIGIN; } catch (e) { return false; }
}

// Save a file the page made. Job card PDFs go in Documents/Firstbox/Job cards/<job card no.>/, invoices in Documents/Firstbox/Invoices/
ipcMain.handle('firstbox:save-file', async (event, name, bytes) => {
  if (!isTrusted(event.senderFrame && event.senderFrame.url)) throw new Error('Not allowed');
  const file = safeName(name);
  const m = /^([A-Z]{2}-\d+)\b/.exec(file);
  const pdf = file.toLowerCase().endsWith('.pdf');
  const dir = pdf && m ? firstboxFolder(path.join('Job cards', m[1])) : pdf && /^(Tax invoice|Proforma) /i.test(file) ? firstboxFolder('Invoices') : firstboxFolder('Files');
  const full = path.join(dir, file);
  fs.writeFileSync(full, Buffer.from(bytes));
  shell.showItemInFolder(full);
  return full;
});
ipcMain.handle('firstbox:open-folder', async (event) => {
  if (!isTrusted(event.senderFrame && event.senderFrame.url)) return;
  return shell.openPath(firstboxFolder(''));
});
ipcMain.handle('firstbox:version', () => app.getVersion());

async function onlineReachable() {
  if (!ONLINE_URL) return false;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 6000);
    const res = await fetch(ONLINE_URL + (ONLINE_URL.includes('?') ? '&' : '?') + 'check=' + Date.now(), { signal: ctrl.signal, cache: 'no-store' });
    clearTimeout(t);
    return res.ok;
  } catch (e) { return false; }
}

async function createWindow() {
  win = new BrowserWindow({
    width: 1380, height: 900, minWidth: 900, minHeight: 600,
    title: 'Firstbox',
    backgroundColor: '#ffffff',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: true
    }
  });
  win.once('ready-to-show', () => win.show());

  // Links to other websites open in the normal browser; the app window stays on Firstbox.
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/i.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!isTrusted(url)) { e.preventDefault(); if (/^https?:/i.test(url)) shell.openExternal(url); } });
  // If the online copy fails part-way (connection lost), fall back to the built-in copy.
  win.webContents.on('did-fail-load', (e, code, desc, url, isMainFrame) => {
    if (isMainFrame && url && !url.startsWith('file://')) win.loadFile(LOCAL_INDEX);
  });

  if (await onlineReachable()) win.loadURL(ONLINE_URL);
  else win.loadFile(LOCAL_INDEX);
}

function buildMenu() {
  const isMac = process.platform === 'darwin';
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    { label: 'File', submenu: [
      { label: 'Open Firstbox folder', click: () => shell.openPath(firstboxFolder('')) },
      { type: 'separator' },
      isMac ? { role: 'close' } : { role: 'quit' }
    ] },
    { role: 'editMenu' },
    { label: 'View', submenu: [
      { label: 'Reload', accelerator: 'CmdOrCtrl+R', click: () => win && win.reload() },
      { type: 'separator' },
      { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' },
      { type: 'separator' }, { role: 'togglefullscreen' }
    ] },
    { role: 'windowMenu' },
    { label: 'Help', submenu: [
      { label: 'About Firstbox', click: () => dialog.showMessageBox(win, { type: 'info', title: 'Firstbox', message: 'Firstbox', detail: 'Version ' + app.getVersion() }) },
      { label: 'Check for updates', click: () => checkForUpdates(true) }
    ] }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// Updates of the app itself (rare: the page updates on its own when online).
// Windows installs updates by itself. Macs show a message with a link to the new download.
async function checkForUpdates(manual) {
  try {
    const { autoUpdater } = require('electron-updater');
    autoUpdater.autoDownload = process.platform === 'win32';
    autoUpdater.on('update-available', info => {
      if (process.platform === 'win32') return;
      const url = CONFIG.downloadsUrl;
      dialog.showMessageBox(win, { type: 'info', title: 'Update available', message: 'Firstbox ' + info.version + ' is available.',
        detail: 'Download the new version and drag it into Applications to replace this one. Your data is not affected.',
        buttons: url ? ['Download', 'Later'] : ['OK'] }).then(r => { if (url && r.response === 0) shell.openExternal(url); });
    });
    autoUpdater.on('update-downloaded', () => {
      dialog.showMessageBox(win, { type: 'info', title: 'Update ready', message: 'A new version of Firstbox is ready.', detail: 'It will be installed when you close Firstbox.', buttons: ['Restart now', 'Later'] })
        .then(r => { if (r.response === 0) autoUpdater.quitAndInstall(); });
    });
    const r = await autoUpdater.checkForUpdates();
    if (manual && (!r || !r.updateInfo || r.updateInfo.version === app.getVersion())) dialog.showMessageBox(win, { type: 'info', message: 'Firstbox is up to date.', detail: 'Version ' + app.getVersion() });
  } catch (e) {
    if (manual) dialog.showMessageBox(win, { type: 'info', message: 'Couldn’t check for updates right now.', detail: String(e && e.message || e) });
  }
}

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
  app.whenReady().then(() => {
    buildMenu();
    createWindow();
    if (app.isPackaged) setTimeout(() => checkForUpdates(false), 8000);
    app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
  });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}
