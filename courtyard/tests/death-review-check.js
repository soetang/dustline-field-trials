'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {CASES,CLIP_NAMES,NAMES,validateArguments,physicsSettings,fixturePaths,validateReview,videoArgs,encodeReplay}=require('./death-review');
let checks=0;
const check=fn=>{fn();checks++;};
const identity=[1,0,0,0,1,0,0,0,1,0,0,0];
const contact=minimum=>({minimum,bone:['foot_l','weapon'],plane:['floor','floor'],finite:true});
const summary={failures:0,failure_labels:[],captures:108,clip_fps:30,clip_requested_ticks:[0,178],clip_note:'Offline replay, not gameplay FPS',
  cases:CASES.map(id=>{
    const [team,placement]=id.split('-');
    return {team,placement,body_count:12,joint_count:10,native_sleep:true,sleep_tick:200,last_recorded_tick:200,recorded_frames:201,
      maximum_tick_gap:1,activation_vertex_delta:0,initial:contact([.003,1.1]),initial_violation:false,
      vertices:team==='ct' ? [3182,551] : [3129,564],activation_usec:6500,backend:'JoltPhysicsDirectSpaceState3D',slop:.005,physics_fps:60,
      contact_sampling:'recorded modifier snapshots; not continuous CCD',transition:{...contact([.002,.001]),samples:201,tick:[2,45]},final:contact([.01,.006])};
  })};
const captures=NAMES.map(name=>{
  const id=name.startsWith('ct-wall-motion-') ? 'ct-wall' : name.replace(/-(early|impact|rest)$/,'');
  const simulation=summary.cases[CASES.indexOf(id)];
  const tick=name.startsWith('ct-wall-motion-') ? Number(name.slice(-3))*2 : name.endsWith('-early') ? 8 : name.endsWith('-impact') ? 45 : 200;
  const poses=Array.from({length:18},(_,index)=>{const value=[...identity];value[9]=index*.01;value[10]=tick*.001;return value;});
  return {name,tick,requested_tick:tick,palette_valid:true,bones:18,fixture:'recorded pose replay; not gameplay or FPS',build:'test-build',
    skin:{valid:true,poses,model_transform:[...identity],skeleton_transform:[...identity],
      palettes:[{mesh:'Operator',bindings:18,rid:String(123+CASES.indexOf(id)),transforms:structuredClone(poses)}]},
    replay_vertex_delta:3e-6,replay_vertex_tolerance:8e-6,contact:contact([.01,.006]),simulation,
    render:{quality:'High',ssao:true,scale_3d:1,viewport_pixels:[960,540],render_3d:[960,540],draw_calls:100,primitives:1000},
    camera:{transform:[...identity],fov:75},paused:true,game_elapsed:0,png:''};
});
const original={captures,summary};
// CPU-only image fixture. Reuse storage; validator hashes each image immediately.
const rgba=Buffer.alloc(960*540*4,128);
const readImage=capture=>{rgba[0]=NAMES.indexOf(capture.name);return {width:960,height:540,data:rgba};};
check(()=>assert.deepEqual(validateReview(captures,summary,readImage),
  {cases:6,captures:108,native_sleep_cases:6,clip_frames:90,clip_fps:30,measurement:'Death-only native-physics pose replay; not gameplay or FPS evidence'}));
const reject=(change,pattern)=>check(()=>{
  const value=structuredClone(original);change(value.captures,value.summary);
  assert.throws(()=>validateReview(value.captures,value.summary,readImage),pattern);
});
reject(values=>values.pop(),/108 captures/);
reject(values=>values[0].name=values[1].name,/exact sequence/);
reject((values,state)=>state.failures=1,/fixture assertions/);
reject((values,state)=>state.failure_labels=['contact failed'],/deep-equal/);
reject((values,state)=>state.cases.pop(),/Six simulation/);
reject((values,state)=>state.cases[0].backend='GodotPhysicsDirectSpaceState3D',/native Jolt/);
reject((values,state)=>state.cases[0].slop=.02,/5 mm/);
reject((values,state)=>state.cases[0].slop=NaN,/Finite/);
reject((values,state)=>state.cases[0].native_sleep=false,/native sleep/);
reject((values,state)=>state.cases[0].sleep_tick=901,/sleep tick/);
reject((values,state)=>state.cases[0].maximum_tick_gap=3,/snapshot gap/);
reject((values,state)=>state.cases[0].recorded_frames=3,/complete recorded timeline/);
reject((values,state)=>state.cases[0].activation_vertex_delta=1e-9,/Exact activation/);
reject((values,state)=>state.cases[0].vertices=[100,20],/Original indexed/);
reject((values,state)=>state.cases[0].body_count=18,/18/);
reject((values,state)=>state.cases[0].joint_count=11,/11/);
reject((values,state)=>state.cases[0].initial_violation=true,/Initial overlap/);
reject((values,state)=>state.cases[0].transition.samples=200,/200/);
reject((values,state)=>state.cases[0].transition.finite=false,/finite indexed/);
reject((values,state)=>state.cases[0].final.minimum[0]=-.0051,/final body/);
reject((values,state)=>state.cases[0].final.minimum[1]=-.0021,/final rifle/);
reject((values,state)=>state.cases[0].transition.minimum[0]=-.0101,/deep transition/);
reject((values,state)=>state.cases[0].transition.minimum[1]=-.0101,/deep transition/);
reject((values,state)=>state.cases[0].transition.minimum=[1,1],/initial and final/);
reject(values=>values[0].requested_tick=7,/fixed-timestep/);
reject(values=>values[0].tick=5,/latest available/);
reject(values=>values[0].paused=false,/paused/);
reject(values=>values[0].game_elapsed=1,/No live/);
reject(values=>values[0].palette_valid=false,/renderer palette/);
reject(values=>values[0].skin.poses.pop(),/Eighteen/);
reject(values=>values[0].skin.poses[0][0]=NaN,/Finite recorded pose/);
reject(values=>values[0].skin.palettes[0].bindings=54,/unaliased/);
reject(values=>values[0].skin.palettes[0].rid='0',/palette RID/);
reject(values=>values[0].skin.palettes[0].transforms.pop(),/palette rows/);
reject(values=>values[0].skin.palettes[0].transforms[0][2]=Infinity,/Finite renderer/);
reject(values=>values[0].replay_vertex_tolerance=.001,/float roundoff/);
reject(values=>values[0].replay_vertex_delta=.0001,/preserve recorded/);
reject(values=>values[0].contact.minimum[0]=-.1,/recorded contact bounds/);
reject(values=>values[0].render.quality='Balanced',/High/);
reject(values=>values[0].render.scale_3d=.5,/1/);
reject(values=>values[0].render.viewport_pixels=[640,360],/960/);
reject(values=>values[1].skin.poses=values[0].skin.poses,/distinct poses/);
reject(values=>values[1].skin.palettes=values[0].skin.palettes,/distinct palettes/);
check(()=>assert.throws(()=>validateReview(captures,summary,()=>({width:1,height:1,data:Buffer.alloc(4)})),/PNG readback/));
check(()=>assert.throws(()=>validateReview(captures,summary,()=>({width:960,height:540,data:Buffer.alloc(4)})),/Complete RGBA/));
check(()=>assert.throws(()=>validateReview(captures,summary,()=>({width:960,height:540,data:rgba})),/visibly different/));
check(()=>assert.throws(()=>validateReview(captures,summary),/signature|PNG|buffer|file|length/i));
check(()=>assert.equal(CLIP_NAMES.length,90));
check(()=>assert.deepEqual(NAMES.slice(6,96),CLIP_NAMES));
check(()=>validateArguments(['--death-review','--capture']));
for(const option of ['--quality=1','--flat-surface','--operator-surface','--wall-review','--profile','--windows-render-only','--width=640'])
  check(()=>assert.throws(()=>validateArguments(['--death-review',option]),/forbid other experiments/));
const source=fs.readFileSync(path.join(__dirname,'../project.godot'),'utf8');
const changed=physicsSettings(source);
check(()=>assert.equal(changed.replace('3d/physics_engine="Jolt Physics"\njolt_physics_3d/simulation/penetration_slop=0.005\n',''),source));
check(()=>assert.throws(()=>physicsSettings(changed),/no implicit/));
const fixture=fs.readFileSync(path.join(__dirname,'death_review.gd'),'utf8');
check(()=>{
  const isolated=fixturePaths(fixture);
  assert.match(isolated,/res:\/\/_death_physics.gd/);
  assert.match(isolated,/res:\/\/_death_geometry.gd/);
  assert.doesNotMatch(isolated,/res:\/\/(engine\/experiments\/death_physics|tests\/fixtures\/death_geometry)/);
});
check(()=>assert.throws(()=>fixturePaths('extends SceneTree'),/isolated preload/));
check(()=>{
  const args=videoArgs('/owned/artifacts');
  assert.deepEqual(args.slice(args.indexOf('-framerate'),args.indexOf('-framerate')+2),['-framerate','30']);
  assert.deepEqual(args.slice(args.indexOf('-frames:v'),args.indexOf('-frames:v')+2),['-frames:v','90']);
  assert.ok(args.includes('libvpx-vp9') && args.includes('-n') && !args.includes('-y'));
  assert.match(args.join(' '),/not gameplay/);
  assert.equal(args.at(-1),'/owned/artifacts/ct-wall-native-pose-replay.webm');
});
check(()=>{
  const previous=process.env.GITHUB_ACTIONS;
  try { delete process.env.GITHUB_ACTIONS;assert.throws(()=>encodeReplay('/never-read'),/remote GitHub-runner-only/); }
  finally { if(previous!==undefined) process.env.GITHUB_ACTIONS=previous; }
});
console.log(`DEATH_REVIEW_CHECK: ${checks}/${checks} passed`);
