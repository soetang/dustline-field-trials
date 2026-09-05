'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
module.exports=async(page,url,uiOnly)=>{
  const failures=[];page.on('pageerror',e=>failures.push(e.message));
  page.setDefaultTimeout(30000);
  if(uiOnly)await page.route('**/boot.js',r=>r.fulfill({contentType:'application/javascript',body:''}));
  await page.goto(url,{waitUntil:'domcontentloaded'});
  if(uiOnly)await page.evaluate(s=>window.desertStrike.render(s),require('./client-state')());
  else await page.waitForFunction(()=>window.desertStrike?.getState(),null,{timeout:90000});
  const input=()=>page.evaluate(()=>window.desertStrike.input());
  const get=()=>page.evaluate(()=>window.desertStrike.getState());
  assert.equal(await page.evaluate(()=>document.body.classList.contains('touch-mode')),true);
  assert.equal(await page.locator('#quality').inputValue(),'low','Phones default to Performance');
  await page.locator('#deploy').tap();
  await page.locator('#touch-controls').waitFor({state:'visible'});
  assert.equal(await page.evaluate(()=>document.pointerLockElement),null,'Touch play must not depend on pointer lock');
  if(uiOnly)assert.equal((await input()).active,true);
  else await page.waitForFunction(()=>window.desertStrike.getState().started);
  // Buy before movement: slow software-rendered input checks can walk out of
  // the real spawn buy radius while waiting for the next HUD packet.
  await page.locator('#touch-buy').tap();await page.locator('#buy-menu').waitFor({state:'visible'});
  assert.equal(await page.locator('#touch-controls').isVisible(),false);
  await page.locator('[data-slot="3"]').tap();
  if(uiOnly)assert.ok((await input()).commands.includes('buy3'));
  else await page.waitForFunction(()=>window.desertStrike.getState().weapon==='DESERT EAGLE');
  await page.locator('#close-buy').tap();await page.locator('#touch-controls').waitFor({state:'visible'});
  const center=async id=>{const b=await page.locator('#'+id).boundingBox();assert.ok(b);return {x:b.x+b.width/2,y:b.y+b.height/2};};
  const cdp=await page.context().newCDPSession(page);
  const fingers=new Map();
  const send=async type=>{
    await cdp.send('Input.dispatchTouchEvent',{type,touchPoints:[...fingers].map(([id,p])=>({id,...p,radiusX:2,radiusY:2,force:1}))});
    await page.waitForTimeout(80); // Flush Chromium's coalesced pointer moves.
  };
  const down=async(id,p)=>{fingers.set(id,p);await send('touchStart');};
  const move=async(id,p)=>{fingers.set(id,p);await send('touchMove');};
  const release=async()=>{fingers.clear();await send('touchEnd');};
  const stick=await center('touch-move');
  let state=await get();
  await down(1,stick);await move(1,{x:stick.x,y:stick.y-35});
  await down(2,{x:430,y:175});await move(2,{x:445,y:170});
  if(uiOnly){const s=await input();assert.ok(s.forward>.6);assert.ok(s.lookX>0,JSON.stringify(s));assert.equal(s.active,true);}
  else {
    await page.waitForFunction(p=>{const s=window.desertStrike.getState();return Math.hypot(s.x-p.x,s.z-p.z)>.3;},state);
    await page.waitForFunction(y=>Math.abs(window.desertStrike.getState().yaw-y)>.01,state.yaw);
  }
  await release();
  console.log('Mobile: deployed without pointer lock; simultaneous movement and swipe aim verified');
  await page.locator('#touch-aim').tap();
  if(uiOnly)assert.equal((await input()).held.aim,true);
  else await page.waitForFunction(()=>window.desertStrike.getState().aiming);
  await page.locator('#touch-aim').tap();
  if(!uiOnly)await page.waitForFunction(()=>window.desertStrike.getState().phase==='live',null,{timeout:60000});
  state=await get();
  await down(3,await center('touch-fire'));
  if(uiOnly){const s=await input();assert.equal(s.held.fire,true);assert.equal(s.firePressed,true);}
  else await page.waitForFunction(ammo=>window.desertStrike.getState().ammo<ammo,state.ammo);
  await release();await page.locator('#touch-reload').tap();
  if(uiOnly)assert.equal((await input()).reloadPressed,true);
  else {
    await page.waitForFunction(()=>window.desertStrike.getState().reload>0);
    await page.waitForFunction(()=>window.desertStrike.getState().reload===0,null,{timeout:40000});
    assert.equal((await get()).ammo,7);
  }
  console.log('Mobile: touch armory, aim toggle, firing and reload verified');
  await down(1,stick);await move(1,{x:stick.x,y:stick.y-25});
  await page.evaluate(()=>window.dispatchEvent(new Event('blur')));
  await page.locator('#pause').waitFor({state:'visible'});await release();
  if(uiOnly){const s=await input();assert.equal(s.active,false);assert.equal(s.forward,0);assert.deepEqual(s.held,{});}
  await page.locator('#resume').tap();await page.locator('#touch-controls').waitFor({state:'visible'});
  if(uiOnly){const s=await input();assert.equal(s.active,true);assert.equal(s.forward,0);assert.deepEqual(s.held,{});}
  else {
    state=await get();await page.waitForTimeout(500);const s=await get();
    assert.ok(Math.hypot(s.x-state.x,s.z-state.z)<.3,'No ghost movement after focus loss');
    const size=await page.locator('#bevy-canvas').evaluate(c=>({w:c.width,logical:innerWidth}));
    assert.ok(size.w<=size.logical*1.1,'Touch Performance mode must cap pixel density');
  }
  if(uiOnly) {
    await page.setViewportSize({width:390,height:844});
    for(const id of ['touch-move','touch-fire','touch-pause','touch-buy','touch-reload']) {
      const box=await page.locator('#'+id).boundingBox();
      assert.ok(box && box.x>=0 && box.y>=0 && box.x+box.width<=391 && box.y+box.height<=845,`${id} must fit portrait`);
    }
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    fs.mkdirSync('artifacts',{recursive:true});
    await page.screenshot({path:'artifacts/mobile-controls-portrait.png'});
    await page.locator('#touch-pause').tap();await page.locator('#pause').waitFor({state:'visible'});
  }
  assert.deepEqual(failures,[]);
  console.log(`Mobile ${uiOnly?'UI':'Wasm gameplay'} checks passed; emulated touch browser, not a physical-phone performance test.`);
};
