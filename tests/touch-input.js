'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
function target(){const events={};return {
  addEventListener(k,f){(events[k]||=[]).push(f);},
  emit(type,values={}){const e={type,pointerType:'touch',timeStamp:0,preventDefault(){},...values};for(const fn of events[type]||[])fn(e);},
  style:{},setAttribute(k,v){this[k]=v;},getBoundingClientRect(){return {left:0,top:0,width:100,height:100};},
  setPointerCapture(){},hasPointerCapture(){return false;},releasePointerCapture(){},
};}
const nodes=new Map(),document=target(),window=target();
document.getElementById=id=>{if(!nodes.has(id))nodes.set(id,target());return nodes.get(id);};
vm.runInNewContext(fs.readFileSync('touch-controls.js','utf8'),{window,document});
let active=true,reloads=0,shops=0,spectates=0;
const controls=window.createDustlineTouchControls({enabled:true,active:()=>active,
  pause:()=>{active=false;controls.reset();},shop:()=>shops++,reload:()=>reloads++,spectate:()=>spectates++});
const emit=(id,type,pointerId,x=50,y=50)=>nodes.get(id).emit(type,{pointerId,clientX:x,clientY:y});
const move=(id,x,y)=>document.emit('pointermove',{pointerId:id,clientX:x,clientY:y});
emit('touch-move','pointerdown',1,50,20);
let state=controls.read();assert.ok(state.forward>.8 && state.forward<1);assert.equal(state.strafe,0);
emit('bevy-canvas','pointerdown',2,200,100);move(2,215,90);
emit('touch-fire','pointerdown',3);
state=controls.read();assert.equal(state.lookX,25.5);assert.equal(state.lookY,-17);assert.equal(state.fire,true);assert.equal(state.firePressed,true);assert.ok(state.forward>.8);
state=controls.read();assert.equal(state.lookX,0);assert.equal(state.firePressed,false);assert.equal(state.fire,true);
document.emit('pointercancel',{pointerId:2});assert.equal(controls.read().fire,true,'Cancelling aim must not release another finger');
document.emit('pointerup',{pointerId:1});state=controls.read();assert.equal(state.forward,0);assert.equal(state.fire,true);
move(3,60,40);state=controls.read();assert.equal(state.lookX,17);assert.equal(state.lookY,-17,'Fire drag must aim');
document.emit('lostpointercapture',{pointerId:3});assert.equal(controls.read().fire,false);
emit('touch-move','pointerdown',4,51,51);state=controls.read();assert.equal(state.forward,0);assert.equal(state.strafe,0,'Joystick dead zone');
move(4,100,0);state=controls.read();assert.ok(Math.abs(Math.hypot(state.forward,state.strafe)-1)<.0001,'Diagonal speed must be bounded');
nodes.get('touch-aim').emit('click');nodes.get('touch-crouch').emit('click');emit('touch-defuse','pointerdown',5);
state=controls.read();assert.ok(state.aim && state.crouch && state.defuse);
nodes.get('touch-reload').emit('click');nodes.get('touch-buy').emit('click');nodes.get('touch-spectate').emit('click');
assert.deepEqual([reloads,shops,spectates],[1,1,1]);
nodes.get('touch-pause').emit('click');state=controls.read();
assert.equal(state.forward,0);assert.ok(!state.fire && !state.aim && !state.crouch && !state.defuse);
emit('touch-fire','pointerdown',6);move(6,100,100);assert.equal(controls.read().fire,false,'Paused touch must be ignored');
active=true;emit('touch-fire','pointerdown',7);window.emit('resize');assert.equal(controls.read().fire,false,'Rotation must not leave fire held');
emit('bevy-canvas','pointerdown',8,200,100);
document.emit('pointerup',{pointerId:8,clientX:204,clientY:102,timeStamp:140});
state=controls.read();assert.ok(state.firePressed && state.fire,'Tap emits an automatic and semi-auto fire pulse');
state=controls.read();assert.ok(!state.firePressed && !state.fire,'Tap pulse drains once');
emit('bevy-canvas','pointerdown',9,200,100);move(9,240,100);move(9,200,100);
document.emit('pointerup',{pointerId:9,clientX:200,clientY:100,timeStamp:100});assert.equal(controls.read().fire,false,'Returning a swipe to its start must not fire');
emit('bevy-canvas','pointerdown',10,200,100);
document.emit('pointerup',{pointerId:10,clientX:200,clientY:100,timeStamp:500});assert.equal(controls.read().fire,false,'Long stationary touch must not fire on release');
emit('bevy-canvas','pointerdown',11,200,100);
document.emit('pointercancel',{pointerId:11,clientX:200,clientY:100,timeStamp:100});assert.equal(controls.read().fire,false,'Cancelled tap must not fire');
emit('touch-move','pointerdown',12,50,20);emit('bevy-canvas','pointerdown',13,200,100);move(13,230,100);
emit('bevy-canvas','pointerdown',14,300,100);
document.emit('pointerup',{pointerId:14,clientX:300,clientY:100,timeStamp:100});
state=controls.read();assert.ok(state.forward>.8 && state.lookX>0 && state.firePressed,'Second-finger tap fires while moving and aiming');
move(13,240,100);assert.ok(controls.read().lookX>0,'Aim finger keeps ownership after another finger taps');
controls.reset();
console.log('Touch input verified: analog/dead-zone movement, three-finger look/fire, drag aim, cancellation, toggles, actions, pause and rotation cleanup.');
