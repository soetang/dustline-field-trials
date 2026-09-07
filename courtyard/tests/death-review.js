'use strict';
// Test-only evidence validation and offline replay encoding. No browser launch.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');

const CASES = ['ct-flat','ct-wall','ct-ramp','t-flat','t-wall','t-ramp'];
const CLIP_NAMES = Array.from({length:90},(_,index)=>`ct-wall-motion-${String(index).padStart(3,'0')}`);
const NAMES = CASES.flatMap(id=>[...['early','impact','rest'].map(phase=>`${id}-${phase}`),...(id==='ct-wall' ? CLIP_NAMES : [])]);
const COUNTS = {ct:[3182,551],t:[3129,564]};
const LABEL = 'Death-only native-physics pose replay; not gameplay or FPS evidence';

function validateArguments(args) {
  assert.ok(args.every(arg=>['--death-review','--capture'].includes(arg)),
    'Death review accepts only --death-review/--capture; preserve High and forbid other experiments');
}

function physicsSettings(source) {
  assert.equal(source.split('[physics]\n').length,2,'Exactly one physics section');
  assert.doesNotMatch(source,/^(?:3d\/physics_engine|jolt_physics_3d\/simulation\/penetration_slop)=/m,
    'Source project has no implicit death-physics backend override');
  return source.replace('[physics]\n','[physics]\n3d/physics_engine="Jolt Physics"\njolt_physics_3d/simulation/penetration_slop=0.005\n');
}

function fixturePaths(source) {
  for(const [before,after] of [
    ['res://engine/experiments/death_physics.gd','res://_death_physics.gd'],
    ['res://tests/fixtures/death_geometry.gd','res://_death_geometry.gd']]) {
    assert.equal(source.split(before).length,2,`One isolated preload: ${before}`);
    source=source.replace(before,after);
  }
  return source;
}

function finite(value,label) { assert.ok(Number.isFinite(value),`Finite ${label}`); return value; }
function integer(value,min,max,label) {
  assert.ok(Number.isInteger(value) && value>=min && value<=max,`${label}: integer ${min}..${max}`);
}
function vector(value,length,label) {
  assert.ok(Array.isArray(value) && value.length===length,`${label}: ${length} components`);
  value.forEach(component=>finite(component,label));
}
function transform(value,label) { vector(value,12,label); }
function contact(value,label) {
  assert.equal(value?.finite,true,`${label}: finite indexed vertices`);
  vector(value.minimum,2,`${label} minima`);
  for(const field of ['bone','plane'])
    assert.ok(Array.isArray(value[field]) && value[field].length===2 && value[field].every(name=>typeof name==='string' && name.length>0),`${label}: ${field} labels`);
}

function validateCase(value,id) {
  const [team,placement]=id.split('-');
  assert.equal(value.team,team);
  assert.equal(value.placement,placement);
  assert.equal(value.backend,'JoltPhysicsDirectSpaceState3D','Actual native Jolt backend');
  assert.ok(Math.abs(finite(value.slop,'penetration slop')-.005)<1e-7,'Jolt 5 mm penetration slop');
  assert.equal(value.physics_fps,60);
  assert.equal(value.body_count,12);
  assert.equal(value.joint_count,10);
  assert.equal(value.native_sleep,true,`${id}: actual native sleep, never timeout freeze`);
  integer(value.sleep_tick,1,900,`${id} sleep tick`);
  assert.equal(value.last_recorded_tick,value.sleep_tick);
  integer(value.recorded_frames,3,902,`${id} recorded frames`);
  integer(value.maximum_tick_gap,1,2,`${id} maximum snapshot gap`);
  assert.ok(value.recorded_frames>=Math.ceil(value.sleep_tick/value.maximum_tick_gap)+1 && value.recorded_frames<=value.sleep_tick+1,
    `${id}: snapshot count spans the complete recorded timeline`);
  assert.equal(value.activation_vertex_delta,0,'Exact activation from original indexed mesh');
  assert.deepEqual(value.vertices,COUNTS[team],'Original indexed body and rifle vertex counts');
  assert.ok(finite(value.activation_usec,'activation usec')>=0);
  for(const field of ['initial','transition','final']) contact(value[field],`${id} ${field}`);
  assert.equal(value.initial_violation,value.initial.minimum.some(distance=>distance<0),'Initial overlap is reported separately');
  assert.equal(value.transition.samples,value.recorded_frames);
  assert.ok(Array.isArray(value.transition.tick) && value.transition.tick.length===2);
  value.transition.tick.forEach(tick=>integer(tick,0,value.sleep_tick,'Worst contact tick'));
  for(let group=0;group<2;group++) {
    assert.ok(value.final.minimum[group]>=(group===0 ? -.005 : -.002),`${id}: final ${group===0 ? 'body' : 'rifle'} clearance`);
    assert.ok(value.transition.minimum[group]>=Math.min(-.01,value.initial.minimum[group]-.005),`${id}: no new deep transition penetration`);
    assert.ok(value.transition.minimum[group]<=Math.min(value.initial.minimum[group],value.final.minimum[group])+1e-7,
      `${id}: transition includes initial and final snapshots`);
  }
  assert.equal(value.contact_sampling,'recorded modifier snapshots; not continuous CCD');
}

function validateReview(captures,summary,readImage) {
  assert.ok(Array.isArray(captures),'Captured image list');
  assert.deepEqual(captures.map(capture=>capture.name),NAMES,'All six cases and 108 captures in exact sequence');
  assert.equal(summary?.failures,0,'All browser fixture assertions pass');
  assert.deepEqual(summary.failure_labels,[]);
  assert.equal(summary.captures,108);
  assert.equal(summary.clip_fps,30);
  assert.deepEqual(summary.clip_requested_ticks,[0,178]);
  assert.match(summary.clip_note,/not gameplay FPS/);
  assert.ok(Array.isArray(summary.cases) && summary.cases.length===6,'Six simulation summaries');
  const cases=new Map();
  summary.cases.forEach((value,index)=>{validateCase(value,CASES[index]);cases.set(CASES[index],value);});
  const images=new Map(),byName=new Map();
  const decode=readImage || (capture=>{
    const png=Buffer.from(capture.png || '','base64');
    assert.ok(png.length>=24 && png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])),'PNG readback signature');
    return require('playwright-core/lib/utilsBundle').PNG.sync.read(png);
  });
  for(const capture of captures) {
    const id=capture.name.startsWith('ct-wall-motion-') ? 'ct-wall' : capture.name.replace(/-(early|impact|rest)$/,'');
    const simulation=cases.get(id);
    assert.deepEqual(capture.simulation,simulation,`${capture.name}: matching simulation summary`);
    integer(capture.tick,0,simulation.sleep_tick,'Recorded source tick');
    const requested=capture.name.startsWith('ct-wall-motion-') ? Number(capture.name.slice(-3))*2
      : capture.name.endsWith('-early') ? 8 : capture.name.endsWith('-impact') ? 45 : simulation.sleep_tick;
    assert.equal(capture.requested_tick,requested,'Original fixed-timestep replay sample');
    assert.ok(capture.tick<=requested && capture.tick>=Math.min(requested,simulation.sleep_tick)-2,'Replay selects the latest available recorded tick');
    assert.equal(capture.paused,true,'Live game remains paused');
    assert.equal(capture.game_elapsed,0,'No live match/AI ticks');
    assert.match(capture.fixture,/not gameplay or FPS/);
    assert.ok(typeof capture.build==='string' && capture.build.length>0,'Source build recorded');
    assert.equal(capture.bones,18);
    assert.equal(capture.palette_valid,true,'Real renderer palette validation');
    assert.equal(capture.skin?.valid,true);
    transform(capture.skin.model_transform,'model transform');
    transform(capture.skin.skeleton_transform,'skeleton transform');
    assert.ok(Array.isArray(capture.skin.poses) && capture.skin.poses.length===18,'Eighteen recorded global poses');
    capture.skin.poses.forEach(pose=>transform(pose,'recorded pose'));
    assert.ok(Array.isArray(capture.skin.palettes) && capture.skin.palettes.length>0,'Actual renderer palettes recorded');
    for(const palette of capture.skin.palettes) {
      assert.equal(palette.bindings,18,'Original unaliased Skin bindings');
      assert.match(palette.rid,/^[1-9]\d*$/,'Actual renderer palette RID');
      assert.ok(typeof palette.mesh==='string' && palette.mesh.length>0);
      assert.ok(Array.isArray(palette.transforms) && palette.transforms.length===18,'All renderer palette rows');
      palette.transforms.forEach(value=>transform(value,'renderer palette'));
    }
    const tolerance=finite(capture.replay_vertex_tolerance,'replay tolerance');
    assert.ok(tolerance>=2e-6 && tolerance<=2e-5,'Replay tolerance stays within float roundoff, not contact padding');
    assert.ok(finite(capture.replay_vertex_delta,'replay vertex delta')>=0 && capture.replay_vertex_delta<=tolerance,'Actual replay vertices preserve recorded pose');
    contact(capture.contact,capture.name);
    capture.contact.minimum.forEach((distance,group)=>assert.ok(distance>=simulation.transition.minimum[group]-tolerance,
      'Visible replay remains within recorded contact bounds'));
    assert.equal(capture.render.quality,'High');
    assert.equal(capture.render.ssao,true);
    assert.equal(capture.render.scale_3d,1);
    assert.deepEqual(capture.render.viewport_pixels,[960,540]);
    assert.deepEqual(capture.render.render_3d,[960,540]);
    assert.ok(finite(capture.render.draw_calls,'draw calls')>0);
    assert.ok(finite(capture.render.primitives,'primitives')>0);
    transform(capture.camera.transform,'camera transform');
    assert.equal(capture.camera.fov,75);
    const image=decode(capture);
    assert.deepEqual([image.width,image.height],[960,540],'Actual PNG readback dimensions');
    assert.equal(image.data.length,960*540*4,'Complete RGBA screenshot');
    images.set(capture.name,crypto.createHash('sha256').update(image.data).digest('hex'));
    byName.set(capture.name,capture);
  }
  for(const id of CASES) {
    const stages=['early','impact','rest'].map(phase=>byName.get(`${id}-${phase}`));
    for(const key of ['poses','palettes'])
      assert.equal(new Set(stages.map(value=>JSON.stringify(value.skin[key]))).size,3,`${id}: three genuinely distinct ${key}`);
    assert.equal(new Set(stages.map(value=>images.get(value.name))).size,3,`${id}: three visibly different poses`);
    for(const stage of stages.slice(1)) assert.deepEqual(stage.camera,stages[0].camera,'Unchanged per-case camera');
  }
  for(const key of ['poses','palettes'])
    assert.ok(new Set(CLIP_NAMES.map(name=>JSON.stringify(byName.get(name).skin[key]))).size>=15,`Clip contains real changing ${key}`);
  assert.ok(new Set(CLIP_NAMES.map(name=>images.get(name))).size>=15,'Clip contains visible motion');
  for(const name of CLIP_NAMES) assert.deepEqual(byName.get(name).camera,byName.get('ct-wall-early').camera,'Clip and stills share camera');
  return {cases:6,captures:108,native_sleep_cases:6,clip_frames:90,clip_fps:30,measurement:LABEL};
}

function videoArgs(directory) {
  return ['-hide_banner','-loglevel','error','-framerate','30','-start_number','0',
    '-i',path.join(directory,'ct-wall-motion-%03d.png'),'-frames:v','90','-c:v','libvpx-vp9',
    '-crf','32','-b:v','0','-pix_fmt','yuv420p','-an','-metadata',`title=${LABEL}`,
    '-metadata','comment=First three seconds at original timing; settled pose shown separately. Offline replay, not gameplay FPS.',
    '-n',path.join(directory,'ct-wall-native-pose-replay.webm')];
}

function encodeReplay(directory) {
  assert.equal(process.env.GITHUB_ACTIONS,'true','VP9 encoding is remote GitHub-runner-only');
  const missing=CLIP_NAMES.filter(name=>!fs.existsSync(path.join(directory,name+'.png')));
  if(missing.length) {
    const metadata={encoded:false,missing,measurement:LABEL};
    fs.writeFileSync(path.join(directory,'death-replay-video.json'),JSON.stringify(metadata,null,2)+'\n');
    return metadata;
  }
  const result=spawnSync('ffmpeg',videoArgs(directory),{encoding:'utf8',timeout:120000,maxBuffer:1024*1024});
  fs.writeFileSync(path.join(directory,'death-replay-encode.log'),(result.stdout||'')+(result.stderr||'')+(result.error ? String(result.error) : ''));
  const metadata={encoded:result.status===0,status:result.status,error:result.error ? String(result.error) : null,
    file:'ct-wall-native-pose-replay.webm',codec:'VP9',fps:30,frames:90,measurement:LABEL};
  fs.writeFileSync(path.join(directory,'death-replay-video.json'),JSON.stringify(metadata,null,2)+'\n');
  return metadata;
}

module.exports={CASES,CLIP_NAMES,NAMES,validateArguments,physicsSettings,fixturePaths,validateReview,videoArgs,encodeReplay};
