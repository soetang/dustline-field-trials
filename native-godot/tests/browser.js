'use strict';
// Real exported engine, real keys/clicks. No gameplay-state mutation or test clock.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const { chromium } = require('playwright');
const { launchBrowser } = require('../../scripts/browser-options');

(async () => {
  const project = path.resolve(__dirname, '..');
  const exported = process.argv.includes('--exported');
  const candidate = fs.readFileSync(path.join(project, 'builds/web-candidate.txt'), 'utf8').trim();
  assert.match(candidate, /^courtyard-[\w-]+$/);
  const root = exported ? path.resolve(project, '../_site') : path.join(project, 'builds/web-releases', candidate);
  const prefix = exported ? '/dustline-field-trials/' : '/dustline-field-trials/courtyard/';
  const types = { '.html':'text/html', '.js':'application/javascript', '.wasm':'application/wasm', '.png':'image/png' };
  const server = http.createServer((req, res) => {
    let pathname;
    try { pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); }
    catch { res.writeHead(400).end(); return; }
    if (pathname === '/favicon.ico') { res.writeHead(204).end(); return; }
    if (!pathname.startsWith(prefix)) { res.writeHead(404).end(); return; }
    let relative = pathname.slice(prefix.length);
    if (!relative || relative.endsWith('/')) relative += 'index.html';
    const file = path.resolve(root, relative);
    if (!file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
    fs.stat(file, (error, stat) => {
      if (error || !stat.isFile()) { res.writeHead(404).end(); return; }
      // Deliberately no COOP/COEP: this must work on ordinary GitHub Pages.
      res.writeHead(200, { 'Content-Type':types[path.extname(file)] || 'application/octet-stream', 'Content-Length':stat.size });
      fs.createReadStream(file).pipe(res);
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = process.env.COURTYARD_URL || `http://127.0.0.1:${server.address().port}${prefix}${exported ? 'courtyard/' : ''}`;
  const artifacts = fs.mkdtempSync(path.resolve(project, '../artifacts/courtyard-browser-'));
  let browser, page;
  const logs = [], failures = [];
  const watchdog = setTimeout(() => { console.error('Courtyard browser check timed out'); browser?.close(); }, 240000);
  watchdog.unref();
  try {
    browser = await launchBrowser(chromium);
    console.log('Browser connected:', url);
    await require('./web-shell')(browser, url, exported);
    page = await browser.newPage({ viewport:{width:1280,height:720}, deviceScaleFactor:Number(process.env.TEST_DPR || 1), acceptDownloads:true });
    if (process.env.DUSTLINE_WINDOWS_BROWSER === '1') {
      // Playwright runs in WSL; its default Linux download path does not exist
      // in Windows Chrome. Use this test's exact, Windows-visible artifact dir.
      const cdp = await page.context().newCDPSession(page);
      const {targetInfo} = await cdp.send('Target.getTargetInfo');
      const downloadPath = execFileSync('wslpath',['-w',artifacts],{encoding:'utf8'}).trim();
      await cdp.send('Browser.setDownloadBehavior',{behavior:'allow',downloadPath,browserContextId:targetInfo.browserContextId});
    }
    page.setDefaultTimeout(30000);
    await page.addInitScript(() => {
      // Avoid headless pointer-lock recenter warps; explicit relative look below.
      document.addEventListener('mousemove', e => { if (e.isTrusted) e.stopImmediatePropagation(); }, true);
      document.addEventListener('pointermove', e => { if (e.isTrusted && e.pointerType === 'mouse') e.stopImmediatePropagation(); }, true);
      // Observe the real engine output. Never create sound or resume on its behalf.
      window.courtyardAudioProbe = [];
      const Original = window.AudioContext || window.webkitAudioContext;
      if (Original) {
        class ObservedAudioContext extends Original {
          constructor(...args) {
            super(...args);
            const analyser = this.createAnalyser();
            const connect = AudioNode.prototype.connect;
            const context = this;
            AudioNode.prototype.connect = function(destination, ...ports) {
              if (destination === context.destination && this !== analyser) connect.call(this, analyser);
              return connect.call(this, destination, ...ports);
            };
            const probe = {context, peak:0};
            window.courtyardAudioProbe.push(probe);
            const data = new Float32Array(analyser.fftSize);
            setInterval(() => { analyser.getFloatTimeDomainData(data); for (const value of data) probe.peak = Math.max(probe.peak, Math.abs(value)); }, 15);
          }
        }
        window.AudioContext = ObservedAudioContext;
        if (window.webkitAudioContext) window.webkitAudioContext = ObservedAudioContext;
      }
    });
    page.on('pageerror', error => { failures.push(error.message); console.error(error); });
    page.on('console', message => {
      logs.push(`${message.type()}: ${message.text()}`);
      if (/Godot|WebGL|DUSTLINE_READY/.test(message.text())) console.log(message.text());
      if (message.type() === 'error') { failures.push(message.text()); console.error(message.text()); }
    });
    page.on('response', response => { if (response.status() >= 400) failures.push(`HTTP ${response.status()} ${response.url()}`); });
    await page.goto(url, {waitUntil:'domcontentloaded'});
    console.log('Page loaded; waiting for the arena');
    await page.waitForFunction(() => window.courtyardState, null, {timeout:120000});
    await page.locator('#loading').waitFor({state:'hidden'});
    const get = () => page.evaluate(() => window.courtyardState);
    let state = await get();
    console.log('Startup:', state);
    assert.equal(state.renderer, 'gl_compatibility');
    assert.equal(state.paused, true);
    assert.equal(state.phase, 'BUY');
    assert.equal(await page.evaluate(() => crossOriginIsolated), false);
    await page.screenshot({path:path.join(artifacts,'menu.png')});
    // Fixed 1280×720 CSS viewport: click the real Godot Deploy button.
    await page.mouse.click(640,328);
    await page.waitForFunction(() => !window.courtyardState.paused && document.pointerLockElement?.id === 'canvas');
    const frozen = await get();
    await page.keyboard.down('KeyW');
    await page.waitForTimeout(650);
    await page.keyboard.up('KeyW');
    state = await get();
    assert.equal(state.position_xyz[0], frozen.position_xyz[0]);
    assert.equal(state.position_xyz[2], frozen.position_xyz[2]);
    console.log('Buy freeze and pointer capture passed');
    await page.keyboard.press('KeyB');
    await page.waitForFunction(() => window.courtyardState.buy_open);
    await page.waitForTimeout(400);
    assert.equal((await get()).paused, false, 'Opening armory must not pause');
    await page.keyboard.press('KeyB');
    await page.waitForFunction(() => !window.courtyardState.buy_open && document.pointerLockElement?.id === 'canvas');
    await page.waitForFunction(() => window.courtyardState.phase === 'LIVE', null, {timeout:60000});
    state = await get();
    await page.keyboard.down('KeyW');
    await page.waitForFunction(p => Math.hypot(window.courtyardState.position_xyz[0]-p[0], window.courtyardState.position_xyz[2]-p[2]) > .8, state.position_xyz);
    await page.keyboard.up('KeyW');
    const yaw = (await get()).yaw;
    console.log('Movement passed; checking relative look');
    await page.evaluate(() => document.getElementById('canvas').dispatchEvent(new PointerEvent('pointermove',{pointerId:1,pointerType:'mouse',movementX:70,movementY:0,bubbles:true})));
    await page.waitForFunction(y => Math.abs(window.courtyardState.yaw-y)>.02, yaw);
    await page.mouse.down();
    await page.waitForFunction(() => window.courtyardState.ammo < 28);
    await page.mouse.up();
    console.log('Move, look, automatic fire passed');
    await page.keyboard.press('KeyR');
    await page.waitForFunction(() => window.courtyardState.reload_left > 0);
    await page.waitForFunction(() => window.courtyardState.ammo === 30 && window.courtyardState.reload_left === 0);
    const audio = await page.evaluate(() => window.courtyardAudioProbe.map(p => ({state:p.context.state, peak:p.peak})));
    assert.ok(audio.some(p => p.state === 'running' && p.peak > .001), `No real browser audio signal: ${JSON.stringify(audio)}`);
    console.log('Reload and audible engine output passed:', audio);
    await page.screenshot({path:path.join(artifacts,'gameplay.png')});
    const downloadPromise = page.waitForEvent('download');
    await page.keyboard.press('F8');
    const download = await downloadPromise;
    assert.equal(download.suggestedFilename(), 'courtyard.png');
    const downloaded = path.join(artifacts, 'courtyard.png');
    if (process.env.DUSTLINE_WINDOWS_BROWSER === '1') {
      const deadline = Date.now()+20000;
      while (!fs.existsSync(downloaded) && Date.now()<deadline) await new Promise(resolve=>setTimeout(resolve,100));
    } else await download.saveAs(downloaded);
    assert.equal(fs.readFileSync(downloaded).readUInt32BE(0), 0x89504e47);
    await page.evaluate(() => document.exitPointerLock());
    await page.waitForFunction(() => window.courtyardState.paused);
    await page.waitForTimeout(250);
    const paused = await get();
    await page.keyboard.down('KeyW');
    await page.waitForTimeout(350);
    await page.keyboard.up('KeyW');
    state = await get();
    assert.equal(state.elapsed, paused.elapsed);
    assert.deepEqual(state.position_xyz, paused.position_xyz);
    await page.mouse.click(640,485);
    await page.locator('#feedback').waitFor({state:'visible'});
    const feedback = JSON.parse(await page.locator('#feedback-text').inputValue());
    assert.equal(feedback.build, state.build);
    assert.equal(feedback.paused, true);
    await page.locator('#close-feedback').click();
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => !window.courtyardState.paused && document.pointerLockElement?.id === 'canvas');
    assert.deepEqual(failures, [], 'Browser runtime or network errors');
    console.log('PASS: exported browser startup, buy freeze, move/look/fire/reload, audio, screenshot download, pause/resume.');
  } catch (error) {
    if (page && !page.isClosed()) {
      console.error('Last state:', await page.evaluate(() => window.courtyardState).catch(() => null));
      await page.screenshot({path:path.join(artifacts,'failure.png'),timeout:5000}).catch(() => {});
    }
    throw error;
  } finally {
    clearTimeout(watchdog);
    fs.writeFileSync(path.join(artifacts,'console.log'), logs.join('\n'));
    console.log('Browser artifacts:', artifacts);
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode=1; });
