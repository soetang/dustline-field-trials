'use strict';
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const {launchBrowser}=require('../scripts/browser-options');

(async () => {
  const root = path.resolve(__dirname, '..');
  const types = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.png': 'image/png', '.jpg': 'image/jpeg' };
  const server = http.createServer((req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const file = path.resolve(root, '.' + (pathname === '/' ? '/bevy.html' : pathname));
    if (!file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
    fs.stat(file, (error, stat) => {
      if (error || !stat.isFile()) { res.writeHead(404).end(); return; }
      res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Content-Length': stat.size });
      fs.createReadStream(file).pipe(res);
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser, page;
  const recentLogs = [];
  let lastState = null;
  const mobile = process.argv.includes('--mobile') || process.argv.includes('--mobile-ui');
  const performanceMode = process.argv.includes('--performance') || mobile;
  const watchdog = setTimeout(() => { console.error('Browser check exceeded its time budget. Last HUD:', lastState); browser?.close(); }, performanceMode ? 300000 : 180000);
  watchdog.unref();
  try {
    browser = await launchBrowser(chromium);
    // Exercise the full responsive UI, with fewer software-rendered pixels in CI.
    page = await browser.newPage({ viewport: mobile ? {width:844,height:390} : { width: 1000, height: 680 }, deviceScaleFactor: Number(process.env.TEST_DPR || .4), ...(mobile ? {hasTouch:true,isMobile:true} : {}) });
    if (mobile) {
      await require('./mobile-browser')(page, 'http://127.0.0.1:' + server.address().port + '/bevy.html', process.argv.includes('--mobile-ui'));
      return;
    }
    await page.addInitScript(performanceMode => {
      if (performanceMode) localStorage.setItem('desert-strike-settings', JSON.stringify({quality: 'low'}));
      // The headless driver's pointer-lock recentering emits huge mouse warps.
      // Aim checks below provide explicit relative deltas; real clicks/keys and
      // pointer capture still exercise the actual browser input path.
      document.addEventListener('mousemove', event => { if (event.isTrusted) event.stopImmediatePropagation(); }, true);
    }, process.argv.includes('--performance'));
    page.setDefaultTimeout(performanceMode ? 30000 : 15000);
    if (process.argv.includes('--ui-only')) {
      await require('./ui-browser')(page, 'http://127.0.0.1:' + server.address().port + '/bevy.html');
      return;
    }
    process.on('unhandledRejection', error => console.error(error));
    const failures = [];
    const textures = new Set();
    const models = new Set();
    page.on('response', response => { if (response.ok() && /_1k\.jpg$/.test(response.url())) textures.add(response.url()); });
    page.on('response', response => { if (response.ok() && /_operator\.glb$/.test(response.url())) models.add(response.url()); });
    page.on('pageerror', error => { failures.push(error.message); console.error('PAGE ERROR:', error.stack); });
    page.on('console', message => {
      recentLogs.push(`${message.type()}: ${message.text()}`); if (recentLogs.length > 40) recentLogs.shift();
      if (message.type() === 'error') { failures.push(message.text()); console.error('CONSOLE:', message.text()); }
    });
    // Simulate an unusable cached legacy bundle: the release loader must never use it.
    await page.route('**/web/desert_strike.js', route => route.abort());
    await page.goto('http://127.0.0.1:' + server.address().port + '/bevy.html', { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => window.desertStrike?.getState(), null, { timeout: 90000 });
    await page.exposeFunction('recordTestState', s => { lastState = s; });
    await page.evaluate(() => {
      const render = window.desertStrike.render;
      let previous;
      window.playtestStats = {botDistance:0, damagedBotFrames:0, roles:[], frames:0};
      window.desertStrike.render = s => {
        render(s);
        const stats = window.playtestStats; stats.frames++;
        for (let i = 0; i < s.bots.length; i++) {
          const bot = s.bots[i];
          if (bot.intent && !stats.roles.includes(bot.intent)) stats.roles.push(bot.intent);
          if (previous?.round === s.round) {
            stats.botDistance += Math.hypot(bot.x - previous.bots[i].x, bot.z - previous.bots[i].z);
            if (bot.health < previous.bots[i].health) stats.damagedBotFrames++;
          }
        }
        previous = s;
        window.recordTestState({phase:s.phase,time:s.time,phaseTime:s.phaseTime,started:s.started,fps:s.fps,health:s.health,ammo:s.ammo,reload:s.reload,x:s.x,z:s.z,pitch:s.pitch,lock:document.pointerLockElement?.id});
      };
    });
    await page.waitForTimeout(1200);
    const get = () => page.evaluate(() => window.desertStrike.getState());
    let state = await get();
    assert.equal(state.phase, 'buy');
    assert.equal(state.bots.length, 9);
    assert.equal(state.started, false);
    assert.equal(state.map.length, 48); assert.equal(state.map[0].length, 64);
    assert.equal(state.layoutScale, 2);
    if (process.argv.includes('--performance')) assert.equal(state.quality, 'low');
    assert.deepEqual(state.spawn.map(n => Math.round(n * 10) / 10), [32.4, 7.6]);
    assert.deepEqual(state.sites.map(p => p.map(n => Math.round(n * 10) / 10)), [[11.6, 8.8], [52.2, 9.6]]);
    assert.equal(await page.locator('#location').textContent(), 'CT SPAWN');
    assert.ok(await page.locator('#front-menu').isVisible());
    if (process.env.CAPTURE) await page.screenshot({ path: 'artifacts/dustline-menu.png', timeout: 30000 });
    console.log('Verified renderer startup and menu');
    await page.waitForFunction(()=>window.desertStrike.getState().viewModelReady,null,{timeout:60000});
    if(process.argv.includes('--weapon-visuals')) {
      await require('./weapons-browser')(page);
      assert.deepEqual(failures,[],'Weapon models must not cause browser runtime errors');
      return;
    }
    if (process.argv.includes('--startup-only')) {
      assert.equal(textures.size, 6, 'The complete PBR material set was not loaded');
      assert.deepEqual(failures, [], 'Browser runtime errors during startup');
      console.log('3D startup check passed: published Wasm release, arena/HUD metadata, and six material textures. Gameplay was not exercised.');
      return;
    }
    await page.locator('#deploy').click();
    console.log('Deploy clicked', await page.evaluate(() => ({ lock: document.pointerLockElement?.id, state: window.desertStrike.getState().started, pause: !document.getElementById('pause').hidden })));
    await page.waitForFunction(() => document.pointerLockElement?.id === 'bevy-canvas');
    await page.waitForFunction(() => window.desertStrike.getState().started);
    if (process.env.CAPTURE) await page.screenshot({ path: 'artifacts/dustline-expanded-spawn.png', timeout: 30000 });
    console.log('Verified deployment');
    if (process.argv.includes('--capture-spawn')) {
      await page.keyboard.press('F8');
      await page.waitForFunction(() => document.body.classList.contains('screenshot-view'));
      await page.waitForTimeout(500);
      await page.screenshot({path: 'artifacts/dustline-operators-spawn.png', timeout: 20000});
      await page.keyboard.press('Escape'); await page.locator('#resume').click();
      await page.waitForFunction(() => document.pointerLockElement?.id === 'bevy-canvas');
    }
    await page.keyboard.press('KeyB');
    await page.waitForFunction(() => !document.getElementById('buy-menu').hidden);
    console.log('Armory opened');
    await page.locator('[data-slot="2"]').click();
    await page.waitForFunction(() => window.desertStrike.getState().weapon === 'AWP');
    console.log('Verified purchase');
    state = await get(); assert.equal(state.money, 3250); assert.equal(state.ammo, 10);
    if (process.env.CAPTURE) await page.screenshot({ path: 'artifacts/dustline-armory.png', timeout: 30000 });
    // The keyboard purchase must execute exactly once, including after clicking a card.
    await page.keyboard.press('Digit1');
    await page.waitForFunction(() => window.desertStrike.getState().weapon === 'M4A4');
    await page.waitForFunction(() => window.desertStrike.getState().viewModelReady);
    state = await get(); assert.equal(state.money, 150); assert.equal(state.ammo, 30);
    await page.keyboard.press('Digit3');
    await page.waitForTimeout(120);
    assert.equal((await get()).money, 150, 'Unaffordable purchase changed balance');
    await page.locator('#close-buy').click();
    console.log('Armory closed', lastState);
    await page.waitForFunction(() => document.pointerLockElement?.id === 'bevy-canvas');
    // Initial software-GPU shader work can stall wall time while Bevy clamps
    // simulation deltas. Allow preparation to finish on these slow test hosts.
    await page.waitForFunction(() => window.desertStrike.getState().phase === 'live', null, { timeout: performanceMode ? 90000 : 45000 });
    state = await get();
    await page.keyboard.down('KeyW');
    await page.waitForFunction(p => { const s = window.desertStrike.getState(); return Math.hypot(s.x - p.x, s.z - p.z) > .4; }, {x: state.x, z: state.z});
    await page.keyboard.up('KeyW');
    let moved = await get(); assert.ok(Math.hypot(moved.x - state.x, moved.z - state.z) > .3, 'WASD did not move player');
    console.log('Verified movement', {x: moved.x, z: moved.z, fps: moved.fps});
    const yaw = moved.yaw;
    // The headless driver recenters the pointer with cancelling warp deltas.
    await page.evaluate(() => document.dispatchEvent(new MouseEvent('mousemove', {movementX:60,movementY:0,bubbles:true})));
    await page.waitForFunction(y => Math.abs(window.desertStrike.getState().yaw - y) > .01, yaw);
    await page.mouse.down();
    await page.waitForFunction(() => window.desertStrike.getState().ammo < 28);
    await page.mouse.up();
    await page.waitForTimeout(120);
    state = await get(); assert.ok(state.ammo < 28, 'Holding fire did not shoot automatically'); assert.ok(state.shots >= 3);
    console.log('Verified automatic fire', {ammo: state.ammo, phase: state.phase, health: state.health});
    await page.keyboard.press('KeyR');
    await page.waitForFunction(() => window.desertStrike.getState().reload > 0);
    const beforeReload = await get();
    await page.waitForFunction(() => window.desertStrike.getState().reload === 0, null, { timeout: performanceMode ? 30000 : 7000 });
    state = await get(); assert.equal(state.ammo, 30); assert.equal(state.ammo + state.reserve, beforeReload.ammo + beforeReload.reserve);
    console.log('Verified reload');
    await page.mouse.down({ button: 'right' });
    await page.waitForFunction(() => window.desertStrike.getState().aiming);
    await page.mouse.up({ button: 'right' });
    await page.keyboard.down('Tab'); await page.waitForTimeout(100);
    assert.ok(await page.locator('#scoreboard').isVisible()); assert.equal(await page.locator('#score-rows tr').count(), 10);
    await page.keyboard.up('Tab');
    if (process.env.CAPTURE) await page.screenshot({ path: 'artifacts/dustline-gameplay.png', timeout: 30000 });
    await page.evaluate(() => document.exitPointerLock());
    await page.waitForFunction(() => !document.getElementById('pause').hidden);
    await page.waitForTimeout(100);
    const paused = await get();
    await page.keyboard.down('KeyW'); await page.mouse.click(50, 400); await page.waitForTimeout(350); await page.keyboard.up('KeyW');
    const stillPaused = await get();
    assert.equal(stillPaused.time, paused.time, 'Pause did not freeze round time'); assert.equal(stillPaused.z, paused.z, 'Player moved while paused'); assert.equal(stillPaused.shots, paused.shots, 'Player fired behind pause overlay');
    await page.locator('#copy-feedback').click();
    const report = await page.locator('#test-details').inputValue();
    assert.match(report, /64 × 48 metres/); assert.match(report, /release-/); assert.match(report, /What happened:/);
    assert.equal(textures.size, 6, 'The complete PBR material set was not loaded');
    assert.equal(models.size, 2, 'Both operator model assets must load');
    await page.locator('#sensitivity').evaluate(input => { input.value = '1.5'; input.dispatchEvent(new Event('input', {bubbles:true})); });
    await page.locator('#resume').click();
    await page.waitForFunction(() => document.pointerLockElement?.id === 'bevy-canvas');
    await page.waitForFunction(t => window.desertStrike.getState().time < t, paused.time);
    if (process.argv.includes('--playtest')) {
      await page.waitForFunction(() => {
        const stats = window.playtestStats;
        return stats.botDistance > 25 && stats.damagedBotFrames > 0 && stats.roles.includes('REPOSITIONING');
      }, null, {timeout: 60000});
      const report = await page.evaluate(() => ({...window.playtestStats, build:window.desertStrike.release, quality:window.desertStrike.getState().quality, seed:window.desertStrike.getState().seed}));
      fs.writeFileSync(path.join(root, 'artifacts/browser-playtest.json'), JSON.stringify(report, null, 2));
      console.log('Observed live bot combat and repositioning in the rendered game:', report);
    }
    await page.evaluate(() => document.exitPointerLock());
    await page.waitForFunction(() => !document.getElementById('pause').hidden);
    await page.locator('#restart').click();
    await page.waitForFunction(() => window.desertStrike.getState().phase === 'buy');
    state = await get(); assert.deepEqual(state.scores, [0, 0]); assert.equal(state.money, 8000); assert.equal(state.kills, 0);
    assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem('desert-strike-settings')).sensitivity), 1.5);
    await page.evaluate(() => document.exitPointerLock());
    await page.setViewportSize({ width: 960, height: 640 });
    if (process.env.CAPTURE) await page.screenshot({ path: 'artifacts/dustline-pause-small.png', timeout: 30000 });
    assert.deepEqual(failures, [], 'Browser runtime errors');
    const errorPage = await browser.newPage();
    await errorPage.route('**/web/current.json', route => route.fulfill({status: 503, body: 'Unavailable'}));
    await errorPage.goto('http://127.0.0.1:' + server.address().port + '/bevy.html');
    await errorPage.locator('#error').waitFor({ state: 'visible' });
    assert.match(await errorPage.locator('#error').textContent(), /HTTP 503/);
    assert.doesNotMatch(await errorPage.locator('#error').textContent(), /hardware acceleration/);
    await errorPage.close();
    console.log('Browser checks passed: 3D startup, deployment, mouse capture, click and keyboard purchases, economy, movement, automatic fire, reload conservation, aiming, scoreboard, pause isolation, resume, restart, and saved settings.');
  } catch (error) {
    console.error('Original failure:', error);
    console.error('Recent browser logs:', recentLogs.join('\n'));
    console.error('Last received HUD:', lastState);
    if (page) {
      const failedState = page.evaluate(() => { const s = window.desertStrike?.getState(); return { phase: s?.phase, started: s?.started, time: s?.time, fps: s?.fps, health: s?.health, ammo: s?.ammo, lock: document.pointerLockElement?.id }; });
      // A crashed Wasm frame can leave evaluation pending; do not hang cleanup.
      console.error('Failed state:', await Promise.race([failedState.catch(e => e.message), new Promise(resolve => setTimeout(() => resolve('Renderer did not respond within 3 seconds'), 3000))]));
      if (process.env.CAPTURE) await page.screenshot({ path: 'artifacts/dustline-test-failure.png', timeout: 5000 }).catch(() => {});
    }
    throw error;
  } finally {
    clearTimeout(watchdog);
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
