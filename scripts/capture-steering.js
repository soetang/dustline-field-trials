'use strict';
// Bounded, eased relative mouse input, shared by the recorder and fast tests.
// No player positions or game state are modified by this controller.
function steeringStep(yaw,pitch,targetYaw,seconds) {
  if(![yaw,pitch,targetYaw,seconds].every(Number.isFinite))return {dx:0,dy:0};
  const dt=Math.max(0,Math.min(.05,seconds));
  if(dt===0)return {dx:0,dy:0};
  const difference=Math.atan2(Math.sin(targetYaw-yaw),Math.cos(targetYaw-yaw));
  const turn=Math.max(-1.4,Math.min(1.4,difference*3))*dt;
  const tilt=Math.max(-.6,Math.min(.6,(pitch+.035)*3))*dt;
  return {dx:-turn/.0022,dy:tilt/.0022};
}
module.exports={steeringStep};
