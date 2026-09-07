'use strict';
const assert = require('node:assert/strict');

module.exports = async function checkShell(browser, url, exported) {
  // Lightweight real-browser regression, before downloading the game engine.
  const display = await browser.newPage({viewport:{width:1280,height:720},deviceScaleFactor:0.4});
  try {
    await display.goto('data:text/html,<canvas></canvas>');
    const session = await display.context().newCDPSession(display);
    for (let i=0;i<2;i++) {
      const png = await require('./browser-capture')(session,1280,720,0.4);
      assert.equal(png.readUInt32BE(0),0x89504e47);
      const state = await display.evaluate(() => ({dpr:devicePixelRatio,width:innerWidth,height:innerHeight}));
      assert.ok(Math.abs(state.dpr-0.4)<0.0001,'Repeated screenshots preserve fractional test DPR');
      assert.deepEqual([state.width,state.height],[1280,720]);
    }
  } finally { await display.close(); }
  const mobile = await browser.newPage({viewport:{width:844,height:390},hasTouch:true,isMobile:true});
  const downloads = [];
  mobile.on('request', request => { if (/\.(wasm|pck)(?:\?|$)/.test(request.url())) downloads.push(request.url()); });
  try {
    await mobile.goto(url, {waitUntil:'domcontentloaded'});
    await mobile.locator('#load-preview').waitFor({state:'visible'});
    assert.match(await mobile.locator('#status').textContent(), /keyboard and mouse/);
    await mobile.waitForTimeout(200);
    assert.deepEqual(downloads, [], 'Touch visitors should not download an unplayable engine automatically');
    if (exported) assert.equal(new URL(await mobile.locator('#loading a.previous').evaluate(a=>a.href)).pathname, '/dustline-field-trials/');
  } finally { await mobile.close(); }
  const unavailable = await browser.newPage({viewport:{width:1280,height:720}});
  try {
    await unavailable.route('**/index.js', route => route.abort());
    await unavailable.goto(url, {waitUntil:'domcontentloaded'});
    await unavailable.locator('#retry').waitFor({state:'visible'});
    assert.match(await unavailable.locator('#failure').textContent(), /loader could not be downloaded/);
    assert.ok(await unavailable.locator('#loading a.previous').isVisible());
  } finally { await unavailable.close(); }
  console.log('PASS: screenshot DPR stability; touch-device guidance without engine download; missing-loader retry and fallback.');
};
