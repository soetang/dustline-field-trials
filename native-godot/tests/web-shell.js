'use strict';
const assert = require('node:assert/strict');

module.exports = async function checkShell(browser, url, exported) {
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
  console.log('PASS: touch-device guidance without engine download; missing-loader error with retry and fallback.');
};
