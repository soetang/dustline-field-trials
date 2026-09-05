'use strict';
// Real browser input + actual Wasm renderer. No teleports or simulation edits.
// Captures the exported project-site layout, including its repository URL prefix.
const {chromium} = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const {launchBrowser}=require('./browser-options');
const {steeringStep}=require('./capture-steering');
const root = path.resolve(__dirname,'..','_site');
const prefix = '/dustline-field-trials/';
const mime = {'.html':'text/html','.js':'text/javascript','.css':'text/css','.wasm':'application/wasm','.glb':'model/gltf-binary','.jpg':'image/jpeg','.json':'application/json'};
const server = http.createServer((req,res) => {
  const url = new URL(req.url,'http://localhost');
  if (!url.pathname.startsWith(prefix)) {res.writeHead(404).end();return;}
  const file = path.resolve(root,url.pathname.slice(prefix.length) || 'index.html');
  if (!file.startsWith(root + path.sep)) {res.writeHead(403).end();return;}
  fs.stat(file,(err,stat) => {
    if (err || !stat.isFile()) {res.writeHead(404).end();return;}
    res.writeHead(200,{'Content-Type':mime[path.extname(file)] || 'application/octet-stream','Content-Length':stat.size});
    fs.createReadStream(file).pipe(res);
  });
});
const angle = n => Math.atan2(Math.sin(n),Math.cos(n));
function route(map,from,to) {
  const key = (x,z) => z*64+x;
  const start = key(Math.floor(from.x),Math.floor(from.z));
  const end = key(...to);
  const queue = [start], prev = new Map([[start,null]]);
  for (let at=0;at<queue.length && !prev.has(end);at++) {
    const cur=queue[at], x=cur%64,z=Math.floor(cur/64);
    for (const [dx,dz] of [[1,0],[-1,0],[0,1],[0,-1]]) {
      const nx=x+dx,nz=z+dz,k=key(nx,nz);
      if (map[nz]?.[nx]===0 && !prev.has(k)) {prev.set(k,cur);queue.push(k);}
    }
  }
  assert.ok(prev.has(end),'Demo destination must be reachable');
  const result=[];
  for (let at=end;at!==start;at=prev.get(at)) result.unshift({x:at%64+.5,z:Math.floor(at/64)+.5});
  return result;
}
function clearLine(map,a,b,radius=0) {
  const steps=Math.ceil(Math.hypot(a.x-b.x,a.z-b.z)*8);
  for(let i=0;i<=steps;i++) {
    const t=steps?i/steps:0,x=a.x+(b.x-a.x)*t,z=a.z+(b.z-a.z)*t;
    for(const [dx,dz] of [[radius,radius],[-radius,radius],[radius,-radius],[-radius,-radius]])
      if(map[Math.floor(z+dz)]?.[Math.floor(x+dx)]!==0)return false;
  }
  return true;
}
module.exports={route,clearLine,server,prefix};
if(require.main===module)(async()=>{
  let browser,context,page,watchdog;
  fs.mkdirSync('artifacts/video-raw',{recursive:true});
  const output=fs.mkdtempSync('artifacts/video-raw/session-');
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const failures=[];
  try {
    browser=await launchBrowser(chromium);
    context=await browser.newContext({viewport:{width:960,height:640},deviceScaleFactor:Number(process.env.TEST_DPR || 1),recordVideo:{dir:output,size:{width:960,height:640}}});
    page=await context.newPage();
    watchdog=setTimeout(()=>browser.close(),300000);watchdog.unref();
    page.setDefaultTimeout(30000);
    await page.addInitScript(()=>{
      localStorage.setItem('desert-strike-settings',JSON.stringify({quality:'low'}));
      document.addEventListener('mousemove',e=>{if(e.isTrusted)e.stopImmediatePropagation();},true);
    });
    page.on('pageerror',e=>failures.push(e.message));
    page.on('response',r=>{if(r.status()>=400)failures.push(`${r.status()} ${new URL(r.url()).pathname}`);});
    const videoEpoch=Date.now();
    await page.goto(`http://127.0.0.1:${server.address().port}${prefix}`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>window.desertStrike?.getState(),null,{timeout:90000});
    await page.waitForFunction(()=>window.desertStrike.getState().viewModelReady,null,{timeout:60000});
    const renderer=await page.evaluate(()=>{
      const gl=document.getElementById('bevy-canvas').getContext('webgl2');
      const debug=gl.getExtension('WEBGL_debug_renderer_info');
      return gl.getParameter(debug?debug.UNMASKED_RENDERER_WEBGL:gl.RENDERER);
    });
    console.log('Recording renderer:',renderer);
    await page.waitForTimeout(1500);
    await page.locator('#deploy').click();
    await page.waitForFunction(()=>document.pointerLockElement?.id==='bevy-canvas');
    const get=()=>page.evaluate(()=>window.desertStrike.getState());
    await page.keyboard.press('F8');
    await page.waitForFunction(()=>document.body.classList.contains('screenshot-view'));
    await page.waitForTimeout(700);
    await page.screenshot({path:path.join(output,'dustline-spawn.png'),timeout:30000});
    await page.keyboard.press('Escape');await page.locator('#resume').click();
    await page.waitForFunction(()=>window.desertStrike.getState().phase==='live',null,{timeout:90000});
    // Drive relative mouse events on animation frames, not abrupt Node-side yaw
    // jumps. The normal client and simulation consume every movement/fire input.
    await page.evaluate(`(() => {
      const steeringStep=${steeringStep.toString()};
      window.captureDriver={targetYaw:null,frames:[],active:true};
      let previous=performance.now();
      function steer(now) {
        const driver=window.captureDriver;if(!driver.active)return;
        const dt=(now-previous)/1000;previous=now;driver.frames.push(dt*1000);
        const s=window.desertStrike.getState();
        if(driver.targetYaw!==null && s.health>0 && document.pointerLockElement) {
          const delta=steeringStep(s.yaw,s.pitch,driver.targetYaw,dt);
          document.dispatchEvent(new MouseEvent('mousemove',{movementX:delta.dx,movementY:delta.dy,bubbles:true}));
        }
        requestAnimationFrame(steer);
      }
      requestAnimationFrame(steer);
    })()`);
    const start=await get();
    let waypoints=route(start.map,start,[9,26]);
    const clipStart=(Date.now()-videoEpoch)/1000;
    console.log('Capturing live movement, aiming and firing…');
    const deadline=Date.now()+35000;
    let fired=false,travel=0,last=start;
    while(Date.now()<deadline) {
      const s=await get();
      travel+=Math.hypot(s.x-last.x,s.z-last.z);last=s;
      if(s.health<=0 || s.phase!=='live')break;
      while(waypoints.length && Math.hypot(s.x-waypoints[0].x,s.z-waypoints[0].z)<.45)waypoints.shift();
      while(waypoints.length>1 && clearLine(s.map,s,waypoints[1],.28))waypoints.shift();
      const enemy=s.bots.find(b=>b.team==='T'&&b.health>0&&Math.hypot(b.x-s.x,b.z-s.z)<20&&clearLine(s.map,s,b));
      const target=enemy || waypoints[0];
      if(!target)break;
      const yaw=Math.atan2(s.x-target.x,s.z-target.z), turn=angle(yaw-s.yaw);
      await page.evaluate(yaw=>{window.captureDriver.targetYaw=yaw;},yaw);
      if(enemy) {
        await page.keyboard.up('KeyW');
        if(Math.abs(turn)<.18){await page.mouse.down();await page.waitForTimeout(160);await page.mouse.up();fired=true;}
        if(s.ammo<5 && s.reload===0)await page.keyboard.press('KeyR');
      } else {
        await page.keyboard[Math.abs(turn)<.4?'down':'up']('KeyW');
      }
      await page.waitForTimeout(100);
      await page.waitForFunction(t=>window.desertStrike.getState().time!==t,s.time,{timeout:10000});
    }
    await page.keyboard.up('KeyW');await page.mouse.up();
    // Include a brief real firing/reload sample if this random match has not met an enemy yet.
    if(!fired && (await get()).health>0) {
      await page.mouse.down();await page.waitForTimeout(900);await page.mouse.up();
      await page.keyboard.press('KeyR');await page.waitForTimeout(2200);
    }
    const clipEnd=(Date.now()-videoEpoch)/1000;
    const timing=await page.evaluate(()=>{window.captureDriver.active=false;return window.captureDriver.frames;});
    await page.keyboard.press('F8');
    await page.waitForFunction(()=>document.body.classList.contains('screenshot-view'));
    await page.waitForTimeout(500);
    await page.screenshot({path:path.join(output,'dustline-lane.png'),timeout:30000});
    const finish=await get();
    assert.ok(travel>3,'Recording must include real movement');
    assert.deepEqual(failures,[],'Exported site must not have missing assets or runtime errors');
    const release=await page.evaluate(()=>window.desertStrike.release);
    const video=page.video();
    await context.close();context=null;
    const raw=path.join(output,'full-session.webm');
    await video.saveAs(raw);
    const sorted=timing.slice().sort((a,b)=>a-b);
    const cadence={frames:timing.length,averageFps:1000*timing.length/timing.reduce((a,b)=>a+b,0),p95FrameMs:sorted[Math.floor(sorted.length*.95)],longFrames:timing.filter(ms=>ms>100).length};
    const report={clipStart,clipEnd,travel,shots:finish.shots-start.shots,seed:finish.seed,release,renderer,cadence,quality:'Performance; real-time browser rendering; silent',raw,directory:output};
    fs.writeFileSync(path.join(output,'capture.json'),JSON.stringify(report,null,2));
    fs.writeFileSync('artifacts/video-raw/capture.json',JSON.stringify(report,null,2));
    console.log(`Saved review-only screenshots and raw recording in ${output}. Movement ${travel.toFixed(1)}m; clip ${clipStart.toFixed(1)}–${clipEnd.toFixed(1)}s.`,cadence);
  } finally {
    clearTimeout(watchdog);
    if(context)await context.close();if(browser)await browser.close();
    await new Promise(resolve=>server.close(resolve));
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
