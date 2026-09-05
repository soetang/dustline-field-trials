'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
module.exports=async(page,url,uiOnly)=>{
  const failures=[];page.on('pageerror',e=>failures.push(e.message));
  page.setDefaultTimeout(30000);
  if(uiOnly)await page.addInitScript(()=>{
    // Some touch devices report a fine primary pointer. Detection must also use
    // touch capability, and tapping Deploy must not focus the canvas or lock it.
    const match=window.matchMedia.bind(window);
    window.matchMedia=q=>q==='(pointer: coarse)'?{matches:false}:match(q);
    HTMLCanvasElement.prototype.focus=()=>{throw new Error('Touch deployment must not focus the canvas');};
    window.orientationRequests=[];
    Element.prototype.requestFullscreen=async()=>{window.orientationRequests.push('fullscreen');throw new Error('Fullscreen unavailable');};
    Object.defineProperty(screen.orientation,'lock',{configurable:true,value:async value=>{window.orientationRequests.push(value);throw new Error('Orientation lock unavailable');}});
    Object.defineProperty(navigator,'audioSession',{configurable:true,value:{type:'auto'}});
    const NativeAudio=window.AudioContext;
    window.AudioContext=class extends NativeAudio {
      constructor(...args) {
        super(...args);window.testAudioContext=this;
        const createGain=this.createGain.bind(this);let first=true;
        this.createGain=(...args)=>{
          const node=createGain(...args);
          if(first){first=false;window.audioMeter=this.createAnalyser();node.connect(window.audioMeter);}
          return node;
        };
      }
    };
  });
  if(uiOnly)await page.route('**/boot.js',r=>r.fulfill({contentType:'application/javascript',body:''}));
  await page.goto(url,{waitUntil:'domcontentloaded'});
  if(uiOnly)await page.evaluate(s=>window.desertStrike.render(s),require('./client-state')());
  else await page.waitForFunction(()=>window.desertStrike?.getState(),null,{timeout:90000});
  if(!uiOnly)await page.waitForFunction(()=>window.desertStrike.getState().viewModelReady,null,{timeout:60000});
  const input=()=>page.evaluate(()=>window.desertStrike.input());
  const get=()=>page.evaluate(()=>window.desertStrike.getState());
  assert.equal(await page.evaluate(()=>document.body.classList.contains('touch-mode')),true);
  assert.equal(await page.locator('#quality').inputValue(),'low','Phones default to Performance');
  await page.locator('#deploy').tap();
  await page.locator('#touch-controls').waitFor({state:'visible'});
  assert.equal(await page.evaluate(()=>document.pointerLockElement),null,'Touch play must not depend on pointer lock');
  if(uiOnly)assert.equal((await input()).active,true);
  else await page.waitForFunction(()=>window.desertStrike.getState().started);
  if(uiOnly)assert.deepEqual(await page.evaluate(()=>window.orientationRequests),['fullscreen','landscape'],'Rejected orientation APIs must not prevent deployment');
  // Buy before movement: slow software-rendered input checks can walk out of
  // the real spawn buy radius while waiting for the next HUD packet.
  await page.locator('#touch-buy').tap();await page.locator('#buy-menu').waitFor({state:'visible'});
  assert.equal(await page.locator('#touch-controls').isVisible(),false);
  await page.locator('[data-slot="3"]').tap();
  if(uiOnly)assert.ok((await input()).commands.includes('buy3'));
  else await page.waitForFunction(()=>window.desertStrike.getState().weapon==='DESERT EAGLE');
  if(!uiOnly)await page.waitForFunction(()=>window.desertStrike.getState().viewModelReady);
  await page.locator('#close-buy').tap();await page.locator('#touch-controls').waitFor({state:'visible'});
  const center=async id=>{const b=await page.locator('#'+id).boundingBox();assert.ok(b);return {x:b.x+b.width/2,y:b.y+b.height/2};};
  const cdp=await page.context().newCDPSession(page);
  const fingers=new Map();
  const send=async(type,points=[...fingers],timestamp)=>{
    await cdp.send('Input.dispatchTouchEvent',{type,touchPoints:points.map(([id,p])=>({id,...p,radiusX:2,radiusY:2,force:1})),...(timestamp===undefined?{}:{timestamp})});
    await page.waitForTimeout(80); // Flush Chromium's coalesced pointer moves.
  };
  const down=async(id,p)=>{fingers.set(id,p);await send('touchStart');};
  const move=async(id,p)=>{fingers.set(id,p);await send('touchMove');};
  const release=async()=>{fingers.clear();await send('touchEnd');};
  const stick=await center('touch-move');
  let state=await get();
  await down(1,stick);await move(1,{x:stick.x,y:stick.y-35});
  if(!uiOnly && state.phase==='buy') {
    await page.waitForFunction(t=>{const s=window.desertStrike.getState();return s.phase!=='buy'||s.phaseTime<t-.25;},state.phaseTime);
    const frozen=await get();
    if(frozen.phase==='buy')assert.ok(Math.hypot(frozen.x-state.x,frozen.z-state.z)<.01,'Touch must not move during preparation');
    await page.waitForFunction(()=>window.desertStrike.getState().phase==='live',null,{timeout:60000});
  }
  await down(2,{x:430,y:175});await move(2,{x:445,y:170});
  if(uiOnly){const s=await input();assert.ok(s.forward>.6);assert.ok(s.lookX>0,JSON.stringify(s));assert.equal(s.active,true);}
  else {
    await page.waitForFunction(p=>{const s=window.desertStrike.getState();return Math.hypot(s.x-p.x,s.z-p.z)>.3;},state);
    await page.waitForFunction(y=>Math.abs(window.desertStrike.getState().yaw-y)>.01,state.yaw);
  }
  await release();
  console.log('Mobile: deployed without pointer lock; simultaneous movement and swipe aim verified');
  if(!uiOnly)await page.waitForFunction(()=>window.desertStrike.getState().phase==='live',null,{timeout:60000});
  state=await get();
  if(uiOnly)await page.evaluate(()=>{
    window.tapTrace=[];
    for(const type of ['pointerdown','pointerup','pointercancel','lostpointercapture'])document.addEventListener(type,e=>window.tapTrace.push({type,id:e.pointerId,target:e.target.id,x:e.clientX,y:e.clientY,t:e.timeStamp}));
  });
  await down(10,{x:430,y:175});await move(10,{x:450,y:175});
  if(uiOnly)assert.equal((await input()).firePressed,false,'Swiping should look without shooting');
  const tapTime=Date.now()/1000;
  fingers.set(11,{x:505,y:175});await send('touchStart',[...fingers],tapTime);
  // CDP touchEnd takes the released fingers, unlike touchMove. Explicit event
  // timestamps model a real quick tap even on a slow software-rendering host.
  await send('touchEnd',[[11,fingers.get(11)]],tapTime+.12);fingers.delete(11);
  if(uiOnly){const s=await input();assert.ok(s.firePressed && s.held.fire,'Second finger tap must fire while first finger aims: '+JSON.stringify(await page.evaluate(()=>window.tapTrace)));assert.equal((await input()).held.fire,undefined);}
  else await page.waitForFunction(ammo=>window.desertStrike.getState().ammo<ammo,state.ammo);
  await move(10,{x:460,y:175});
  if(uiOnly)assert.ok((await input()).lookX>0,'First finger keeps aiming after another finger fires');
  await release();
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
  assert.equal(await page.locator('#pause').isVisible(),false,'Visible mobile focus changes must not open pause');
  await page.evaluate(()=>window.dispatchEvent(new Event('pagehide')));
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
    await page.locator('#rotate-phone').waitFor({state:'visible'});
    assert.equal((await input()).active,false,'Portrait defaults to a held game while rotating');
    assert.equal(await page.locator('#pause').isVisible(),false,'Rotate guidance must not be mistaken for the pause bug');
    await page.setViewportSize({width:844,height:390});
    await page.locator('#rotate-phone').waitFor({state:'hidden'});
    assert.equal((await input()).active,true,'Physical landscape rotation resumes play');
    await page.setViewportSize({width:390,height:844});
    await page.locator('#continue-portrait').tap();
    assert.equal((await input()).active,true,'Portrait remains an explicit accessibility fallback');
    for(const id of ['touch-move','touch-fire','touch-pause','touch-buy','touch-reload']) {
      const box=await page.locator('#'+id).boundingBox();
      assert.ok(box && box.x>=0 && box.y>=0 && box.x+box.width<=391 && box.y+box.height<=845,`${id} must fit portrait`);
    }
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    fs.mkdirSync('artifacts',{recursive:true});
    await page.screenshot({path:'artifacts/mobile-controls-portrait.png'});
    await page.locator('#touch-pause').tap();await page.locator('#pause').waitFor({state:'visible'});
    await page.evaluate(()=>{
      window.orientationRequests=[];
      document.documentElement.requestFullscreen=async()=>{window.orientationRequests.push('fullscreen');};
      Object.defineProperty(screen.orientation,'lock',{configurable:true,value:async value=>window.orientationRequests.push(value)});
    });
    await page.locator('#resume').tap();
    assert.deepEqual(await page.evaluate(()=>window.orientationRequests),['fullscreen','landscape'],'Supported browsers request fullscreen then landscape');
    await page.locator('#touch-pause').tap();
    assert.equal(await page.evaluate(()=>navigator.audioSession.type),'playback');
    await page.evaluate(()=>window.testAudioContext.suspend());
    await page.locator('#test-sound').tap();
    await page.waitForFunction(()=>{
      const samples=new Float32Array(window.audioMeter.fftSize);window.audioMeter.getFloatTimeDomainData(samples);
      return window.testAudioContext.state==='running' && samples.some(n=>Math.abs(n)>.001);
    },null,{polling:20,timeout:3000});
    assert.match(await page.locator('#audio-status').textContent(),/Test tones sent/);
    await page.evaluate(()=>window.testAudioContext.suspend());
    await page.locator('#pause-heading').tap();
    await page.waitForFunction(()=>window.testAudioContext.state==='running',null,{timeout:3000});
    await page.locator('#volume').evaluate(el=>{el.value=0;el.dispatchEvent(new Event('input'));});
    await page.locator('#test-sound').tap();assert.match(await page.locator('#audio-status').textContent(),/Muted/);
    assert.match(await page.evaluate(()=>window.desertStrike.getDiagnostics()),/game volume: 0%/);
    await page.evaluate(()=>window.testAudioContext.close());
    await page.locator('#test-sound').tap();
    assert.equal(await page.evaluate(()=>window.testAudioContext.state),'running','Closed audio context must be recreated');
    console.log('Mobile audio: measured nonzero generated samples, recovered suspension, respected mute and recreated a closed context.');
  }
  assert.deepEqual(failures,[]);
  console.log(`Mobile ${uiOnly?'UI':'Wasm gameplay'} checks passed; emulated touch browser, not a physical-phone performance test.`);
};
