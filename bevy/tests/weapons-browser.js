'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
const path=require('node:path');
module.exports=async(page,{standard=false}={})=>{
  const artifacts=path.resolve(__dirname,'../../artifacts/weapons');
  fs.mkdirSync(artifacts,{recursive:true});
  const rejoin=async()=>{
    for(let attempt=0;attempt<3;attempt++) {
      await page.waitForFunction(()=>document.pointerLockElement?.id==='bevy-canvas'||!document.getElementById('pause').hidden);
      if(await page.evaluate(()=>document.pointerLockElement?.id==='bevy-canvas'))return;
      // Chromium may temporarily reject recapture directly after screenshot
      // mode releases the pointer. Exercise the normal visible rejoin action.
      await page.waitForTimeout(1300);
      await page.locator('#resume').click();
    }
    await page.waitForFunction(()=>document.pointerLockElement?.id==='bevy-canvas');
  };
  await page.locator('#deploy').click();
  if(standard) {
    await rejoin();
    await page.evaluate(()=>document.exitPointerLock());
    await page.locator('#pause').waitFor({state:'visible'});
    await page.locator('#quality').selectOption('standard');
    await page.waitForFunction(()=>window.desertStrike.getState().quality==='standard');
    await page.locator('#resume').click();
  }
  const cases=[['m4',0,'M4A4'],['ak',1,'AK-47'],['awp',2,'AWP'],['deagle',3,'DESERT EAGLE']];
  for(const [index,[file,slot,name]] of cases.entries()) {
    if(index)await page.locator('#restart').click(); // Fresh legitimate buy budget.
    await rejoin();
    await page.waitForFunction(()=>window.desertStrike.getState().phase==='buy');
    if(slot) {
      await page.keyboard.press('KeyB');await page.locator('#buy-menu').waitFor({state:'visible'});
      await page.locator(`[data-slot="${slot}"]`).click();
      await page.waitForFunction(name=>{const s=window.desertStrike.getState();return s.weapon===name && s.viewModelReady;},name,{timeout:60000});
      await page.locator('#close-buy').click();
      await rejoin();
    }
    await page.keyboard.press('F8');
    await page.waitForFunction(()=>document.body.classList.contains('screenshot-view'));
    // CPU-side scene readiness precedes render extraction/presentation. Let
    // the selected model reach the compositor before photographing it.
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))));
    await page.screenshot({path:path.join(artifacts,`${file}.png`),timeout:30000});
    assert.equal((await page.evaluate(()=>window.desertStrike.getState())).weapon,name);
    await page.keyboard.press('F8');await page.locator('#pause').waitFor({state:'visible'});
    console.log(`Actual ${name} view model loaded and photographed.`);
  }
};
