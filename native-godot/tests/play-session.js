'use strict';
// Persistent, bounded UI-only session for screenshot-guided human/agent review.
// No game-state writes, auto-aim, route planner, slow motion or automatic pause.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { chromium } = require('playwright');
const { launchBrowser } = require('../../scripts/browser-options');

(async () => {
  const url = process.env.COURTYARD_URL || 'https://soetang.github.io/dustline-field-trials/courtyard/';
  assert.ok(['127.0.0.1','localhost','soetang.github.io'].includes(new URL(url).hostname));
  const folder = fs.mkdtempSync(path.resolve(__dirname,'../../artifacts/vision-play-'));
  const browser = await launchBrowser(chromium);
  const page = await browser.newPage({viewport:{width:1280,height:720},deviceScaleFactor:0.5});
  let input;
  const watchdog = setTimeout(() => { input?.close(); browser.close(); },360000);
  const log = event => fs.appendFileSync(path.join(folder,'session.jsonl'),JSON.stringify({time:new Date().toISOString(),...event})+'\n');
  let frame = 0;
  async function snapshot() {
    const file = path.join(folder,`frame-${String(frame++).padStart(3,'0')}.png`);
    await page.screenshot({path:file});
    console.log(JSON.stringify({screenshot:file}));
    log({screenshot:file});
  }
  try {
    // Headless Chromium generates recenter warps after pointer capture. Remove
    // those OS deltas; look commands below send ordinary relative input events.
    await page.addInitScript(() => {
      for (const type of ['mousemove','pointermove']) document.addEventListener(type,e=>{
        if (e.isTrusted && (type==='mousemove' || e.pointerType==='mouse')) e.stopImmediatePropagation();
      },true);
    });
    page.on('console',message=>log({console:message.text(),type:message.type()}));
    page.on('pageerror',error=>log({error:error.message}));
    await page.goto(url,{waitUntil:'domcontentloaded'});
    // Read startup readiness only, never enemy positions or combat decisions.
    await page.waitForFunction(()=>window.courtyardState,null,{timeout:120000});
    await page.locator('#loading').waitFor({state:'hidden'});
    console.log('VISION_SESSION_READY '+folder+'; send one JSON action per line; {"quit":true} closes.');
    await snapshot();
    input = readline.createInterface({input:process.stdin,crlfDelay:Infinity});
    const movement = new Set(['KeyW','KeyA','KeyS','KeyD','ShiftLeft','ControlLeft','Space']);
    const presses = new Set(['Enter','Escape','KeyR','KeyB','F3','Digit1','Digit2','Digit3','Digit4','KeyE']);
    for await (const line of input) {
      let held = [], firing = false, aiming = false;
      try {
        const command = JSON.parse(line);
        log({action:command});
        if (command.quit) break;
        const keys = command.keys || [];
        assert.ok(Array.isArray(keys) && keys.every(key=>movement.has(key)));
        held = keys;
        const ms = command.ms ?? 0;
        assert.ok(Number.isFinite(ms) && ms>=0 && ms<=2000,'Actions are capped at two seconds');
        for (const key of command.press || []) { assert.ok(presses.has(key)); await page.keyboard.press(key); }
        if (command.click) {
          const [x,y] = command.click;
          assert.ok(Number.isFinite(x) && Number.isFinite(y) && x>=0 && x<=1280 && y>=0 && y<=720);
          await page.mouse.click(x,y);
        }
        for (const key of held) await page.keyboard.down(key);
        if (command.fire) { await page.mouse.down(); firing = true; }
        if (command.aim) { await page.mouse.down({button:'right'}); aiming = true; }
        const [dx,dy] = command.look || [0,0];
        assert.ok(Number.isFinite(dx) && Number.isFinite(dy) && Math.abs(dx)<=1800 && Math.abs(dy)<=900);
        const steps = Math.max(1,Math.ceil(ms/100));
        for (let i=0;i<steps;i++) {
          if (dx || dy) await page.evaluate(([x,y])=>document.getElementById('canvas').dispatchEvent(
            new PointerEvent('pointermove',{pointerId:1,pointerType:'mouse',movementX:x,movementY:y,bubbles:true})),[dx/steps,dy/steps]);
          if (ms) await page.waitForTimeout(ms/steps);
        }
      } catch (error) { console.error(error.message); log({actionError:error.message}); }
      finally {
        for (const key of held) if (movement.has(key)) await page.keyboard.up(key);
        if (firing) await page.mouse.up();
        if (aiming) await page.mouse.up({button:'right'});
      }
      await snapshot();
    }
  } finally {
    clearTimeout(watchdog);
    input?.close();
    await browser.close();
  }
})().catch(error=>{ console.error(error); process.exitCode=1; });
