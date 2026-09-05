'use strict';
const assert=require('node:assert/strict');
const {steeringStep}=require('../scripts/capture-steering');
const {graphicsArgs}=require('../scripts/browser-options');
const original=process.env.DUSTLINE_GPU;
try {
  delete process.env.DUSTLINE_GPU;
  assert.ok(graphicsArgs().includes('--use-angle=swiftshader'));
  process.env.DUSTLINE_GPU='1';
  assert.ok(graphicsArgs().includes('--use-angle=gl'));
  assert.ok(!graphicsArgs().includes('--use-angle=swiftshader'));
}finally{if(original===undefined)delete process.env.DUSTLINE_GPU;else process.env.DUSTLINE_GPU=original;}
const angle=n=>Math.atan2(Math.sin(n),Math.cos(n));
for(const fps of [20,30,60,144]) {
  let yaw=3.1,pitch=.4;
  const target=-2.2;
  for(let i=0;i<fps*4;i++) {
    const before=Math.abs(angle(target-yaw));
    const {dx,dy}=steeringStep(yaw,pitch,target,1/fps);
    assert.ok(Math.abs(dx*.0022)<=1.4/fps+1e-9,'Turns must be speed-limited');
    yaw=angle(yaw-dx*.0022);pitch-=dy*.0022;
    assert.ok(Math.abs(angle(target-yaw))<=before+1e-9,'Steering must converge without overshoot');
  }
  assert.ok(Math.abs(angle(target-yaw))<.001);
  assert.ok(Math.abs(pitch+.035)<.001);
}
assert.ok(Math.abs(steeringStep(0,0,3,5).dx*.0022)<=.07+1e-9,'A delayed frame must not snap the view');
assert.deepEqual(steeringStep(NaN,0,0,1),{dx:0,dy:0});
assert.deepEqual(steeringStep(0,0,0,-1),{dx:0,dy:0});
console.log('Capture tools verified: bounded smooth aiming and opt-in hardware renderer.');
