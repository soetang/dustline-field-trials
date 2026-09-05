'use strict';
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  const root = path.resolve(__dirname, '..');
  const server = http.createServer((req, res) => {
    const name = new URL(req.url, 'http://localhost').pathname;
    const file = path.resolve(root, '.' + (name === '/' ? '/index.html' : name));
    if (!file.startsWith(root + path.sep)) return res.writeHead(403).end();
    fs.stat(file, (error, stat) => {
      if (error || !stat.isFile()) return res.writeHead(404).end();
      res.writeHead(200, {'Content-Type': {'.html':'text/html','.css':'text/css','.js':'application/javascript'}[path.extname(file)] || 'application/octet-stream'});
      fs.createReadStream(file).pipe(res);
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  let browser;
  try {
    browser = await chromium.launch({headless: true});
    const page = await browser.newPage({viewport:{width:1200,height:800}});
    page.setDefaultTimeout(12000);
    const errors = []; page.on('pageerror', e => errors.push(e.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.locator('#play-button').click();
    await page.waitForFunction(() => document.pointerLockElement?.id === 'game' && window.DesertStrike.getState().state === 'playing');
    const get = () => page.evaluate(() => window.DesertStrike.getState());
    const start = await get();
    await page.keyboard.down('KeyW');
    await page.waitForFunction(p => {const s = window.DesertStrike.getState(); return Math.hypot(s.x-p.x,s.y-p.y) > .3;}, start, {timeout:5000});
    await page.keyboard.up('KeyW');
    // Chromium's headless pointer-lock driver emits equal opposite warp deltas.
    // Send a relative mouse event to exercise the actual browser input listener.
    await page.evaluate(() => document.dispatchEvent(new MouseEvent('mousemove', {movementX:60,movementY:0,bubbles:true})));
    await page.waitForFunction(a => Math.abs(window.DesertStrike.getState().playerAngle-a) > .01, start.playerAngle);
    await page.mouse.down(); await page.waitForFunction(() => window.DesertStrike.getState().ammo < 28); await page.mouse.up();
    assert.ok((await get()).ammo < 28, 'Holding M4 fire must repeat');
    await page.keyboard.press('KeyB');
    await page.waitForFunction(() => window.DesertStrike.getState().state === 'buying');
    await page.locator('[data-slot="3"]').click();
    assert.equal((await get()).weapon, 'awp'); assert.equal((await get()).money, 3250);
    await page.keyboard.press('KeyB');
    await page.waitForFunction(() => document.pointerLockElement?.id === 'game');
    await page.mouse.down({button:'right'});
    await page.waitForFunction(() => !document.getElementById('scope').hidden);
    await page.mouse.down(); await page.waitForTimeout(1250); await page.mouse.up();
    assert.equal((await get()).ammo, 9, 'AWP must require another trigger press');
    await page.mouse.up({button:'right'});
    await page.keyboard.press('KeyR');
    await page.waitForFunction(() => window.DesertStrike.getState().reloading > 0);
    await page.waitForFunction(() => window.DesertStrike.getState().reloading === 0);
    assert.equal((await get()).ammo, 10); assert.equal((await get()).reserve, 29);
    await page.keyboard.down('Tab');
    await page.waitForFunction(() => document.querySelectorAll('#classic-score-rows tr').length === 10);
    await page.keyboard.up('Tab');
    await page.screenshot({path:'artifacts/classic-improved-gameplay.png'});
    await page.evaluate(() => document.exitPointerLock());
    await page.waitForFunction(() => window.DesertStrike.getState().state === 'paused');
    const paused = await get(); await page.waitForTimeout(200);
    assert.equal((await get()).roundTime, paused.roundTime);
    await page.locator('#resume-button').click();
    await page.waitForFunction(() => window.DesertStrike.getState().state === 'playing');
    assert.deepEqual(errors, []);
    console.log('Classic browser passed: immediate movement, mouse look, automatic fire, clickable buying, scope, semi-auto fire, reload accounting, scoreboard, and pause/resume.');
  } finally { if (browser) await browser.close(); await new Promise(resolve => server.close(resolve)); }
})().catch(error => { console.error(error); process.exitCode = 1; });
