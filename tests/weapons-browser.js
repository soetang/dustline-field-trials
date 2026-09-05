'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
module.exports=async page=>{
  fs.mkdirSync('artifacts/weapons',{recursive:true});
  await page.locator('#deploy').click();
  const cases=[['m4',0,'M4A4'],['ak',1,'AK-47'],['awp',2,'AWP'],['deagle',3,'DESERT EAGLE']];
  for(const [index,[file,slot,name]] of cases.entries()) {
    if(index)await page.locator('#restart').click(); // Fresh legitimate buy budget.
    await page.waitForFunction(()=>document.pointerLockElement?.id==='bevy-canvas');
    await page.waitForFunction(()=>window.desertStrike.getState().phase==='buy');
    if(slot) {
      await page.keyboard.press('KeyB');await page.locator('#buy-menu').waitFor({state:'visible'});
      await page.locator(`[data-slot="${slot}"]`).click();
      await page.waitForFunction(name=>{const s=window.desertStrike.getState();return s.weapon===name && s.viewModelReady;},name,{timeout:60000});
      await page.locator('#close-buy').click();
      await page.waitForFunction(()=>document.pointerLockElement?.id==='bevy-canvas');
    }
    await page.keyboard.press('F8');
    await page.waitForFunction(()=>document.body.classList.contains('screenshot-view'));
    await page.screenshot({path:`artifacts/weapons/${file}.png`,timeout:30000});
    assert.equal((await page.evaluate(()=>window.desertStrike.getState())).weapon,name);
    await page.keyboard.press('F8');await page.locator('#pause').waitFor({state:'visible'});
    console.log(`Actual ${name} view model loaded and photographed.`);
  }
};
