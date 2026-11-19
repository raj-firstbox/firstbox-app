// CI check: start the built app, wait for the sign-in screen, save a screenshot.
const { _electron: electron } = require('playwright-core');
const path = require('path'), fs = require('fs');
(async () => {
  const exe = process.platform === 'darwin'
    ? path.join('dist', 'mac-arm64', 'Firstbox.app', 'Contents', 'MacOS', 'Firstbox')
    : path.join('dist', 'win-unpacked', 'Firstbox.exe');
  if (!fs.existsSync(exe)) throw new Error('App not found at ' + exe);
  const app = await electron.launch({ executablePath: exe, timeout: 60000 });
  const win = await app.firstWindow();
  await win.waitForSelector('#fbc-auth', { timeout: 45000 });
  await win.waitForTimeout(1500);
  const out = path.join('dist', 'smoke-' + process.platform + '.png');
  await win.screenshot({ path: out });
  console.log('App started. Title:', await win.title(), '| page:', win.url(), '| screenshot:', out);
  console.log('Has desktop bridge:', await win.evaluate(() => !!window.firstboxDesktop));
  await app.close();
})().catch(e => { console.error(e); process.exit(1); });
