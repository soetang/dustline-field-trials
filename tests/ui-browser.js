'use strict';
const assert = require('node:assert/strict');

// Exercise the real DOM, CSS and browser mouse capture without loading Bevy.
// This is a fast UI check, not a substitute for the full 3D integration test.
module.exports = async (page, url) => {
  const failures = [];
  page.on('pageerror', error => failures.push(error.message));
  await page.route('**/boot.js', route => route.fulfill({contentType: 'application/javascript', body: ''}));
  await page.goto(url, {waitUntil: 'domcontentloaded'});
  await page.evaluate(s => window.desertStrike.render(s), require('./client-state')());
  const input = () => page.evaluate(() => window.desertStrike.input());
  await page.locator('#deploy').click();
  await page.waitForFunction(() => document.pointerLockElement?.id === 'bevy-canvas');
  assert.equal((await input()).active, true);
  await page.keyboard.down('KeyW'); await page.mouse.down();
  await page.keyboard.press('F8');
  await page.waitForFunction(() => document.pointerLockElement === null);
  assert.equal((await input()).active, false);
  assert.deepEqual((await input()).held, {});
  assert.equal(await page.locator('#pause').isVisible(), false);
  assert.equal(await page.locator('#bevy-hud').isVisible(), false);
  assert.equal(await page.locator('.screen-grain').isVisible(), false);
  assert.equal(await page.locator('#screenshot-exit').isVisible(), true);
  await page.mouse.up(); await page.keyboard.up('KeyW');
  await page.evaluate(() => window.dispatchEvent(new Event('blur')));
  assert.equal(await page.locator('#pause').isVisible(), false, 'Screenshot tool focus loss revealed the menu');
  assert.equal((await input()).active, false);
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('#pause').isVisible(), true);
  assert.equal((await input()).active, false, 'Exiting screenshot view resumed combat');
  await page.locator('#screenshot-mode').click();
  assert.equal(await page.locator('#pause').isVisible(), false);
  await page.locator('#screenshot-exit').click();
  assert.equal(await page.locator('#pause').isVisible(), true);
  await page.locator('#resume').click();
  await page.waitForFunction(() => document.pointerLockElement?.id === 'bevy-canvas');
  assert.equal((await input()).active, true);
  assert.deepEqual((await input()).held, {});
  await page.keyboard.press('F8'); await page.keyboard.press('F8');
  assert.equal(await page.locator('#pause').isVisible(), true);
  assert.equal((await input()).active, false);
  assert.equal(await page.locator('#bevy-hud').isVisible(), true);
  assert.deepEqual(failures, []);
  console.log('Fast browser UI checks passed: real pointer capture, F8 screenshot view, hidden HUD/menu, blur-safe pause, button/keyboard exit, and clean resume. Renderer was intentionally not loaded.');
};
