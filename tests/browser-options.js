'use strict';
const assert=require('node:assert/strict');
const {launchBrowser}=require('../scripts/browser-options');

(async()=>{
  const saved={...process.env};
  try {
    process.env.DISPLAY=':0';
    process.env.WAYLAND_DISPLAY='wayland-0';
    delete process.env.DUSTLINE_WINDOWS_BROWSER;
    delete process.env.DUSTLINE_ALLOW_HOST_INPUT;
    let options;
    const browser={};
    assert.equal(await launchBrowser({launch:async value=>{options=value;return browser;}}),browser);
    assert.equal(options.headless,true);
    assert.equal(options.env.DISPLAY,undefined);
    assert.equal(options.env.WAYLAND_DISPLAY,undefined);
    assert.equal(process.env.DISPLAY,':0','Never change the user session environment');
    process.env.DUSTLINE_WINDOWS_BROWSER='1';
    assert.throws(()=>launchBrowser({}),/can trap the desktop mouse/);
    console.log('PASS: background browser isolation and explicit host-input guard');
  } finally {
    for(const key of Object.keys(process.env)) if(!(key in saved)) delete process.env[key];
    Object.assign(process.env,saved);
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
