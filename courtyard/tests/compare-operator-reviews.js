'use strict';

// Offline artifact comparison. Never launches a browser or touches host input.
const assert = require('node:assert/strict');
const KEY_POSES=['walk-first','walk-next','aim-high','reload','falling','fallen'];
const SLEEP_NAMES=['ct-sleep-entry','ct-sleep-hold','ct-sleep-moved'];
const DEATH_WALL_NAMES=['ct','t'].flatMap(team=>['into','oblique','parallel'].flatMap(angle=>
  ['falling','settled'].map(phase=>`${team}-wall-death-${angle}-${phase}`)));
const NAMES=[...['ct','t'].flatMap(team=>KEY_POSES.map(pose=>`${team}-${pose}`)),
  'ct-squad','ct-squad-edge','ct-squad-distance',...SLEEP_NAMES,...DEATH_WALL_NAMES];

function validateDeathWallStages(captures) {
  const stages=DEATH_WALL_NAMES.map(name=>captures.find(capture=>capture.name===name));
  assert.ok(stages.every(Boolean),'All twelve wall-death diagnostic stages are present');
  const vector=(value,size,label)=>assert.ok(Array.isArray(value) && value.length===size && value.every(Number.isFinite),`Finite ${label}`);
  const count=(value,label)=>assert.ok(Number.isInteger(value) && value>=0,`Nonnegative ${label}`);
  return stages.map(capture=>{
    const value=capture.death_wall;
    assert.ok(value && value.schema===1,'Wall-death diagnostic schema is present');
    const [,team,angle,phase]=capture.name.match(/^(ct|t)-wall-death-(into|oblique|parallel)-(falling|settled)$/);
    assert.equal(value.team,team);
    assert.equal(value.phase,phase);
    assert.equal(value.angle_degrees,{into:0,oblique:45,parallel:90}[angle]);
    assert.equal(value.prewarm_ticks,60,'One second of live wall contact precedes death');
    assert.ok(Number.isFinite(value.starting_withdrawal) && value.starting_withdrawal>=0 && value.starting_withdrawal<=1,'Finite live prewarm withdrawal');
    assert.equal(typeof value.starting_cached_clear,'boolean','Live prewarm clearance is reported');
    assert.equal(value.death_ticks,phase==='falling' ? 8 : 60,'Deterministic actual death callbacks');
    assert.equal(value.health,0);
    assert.equal(value.paused,true,'No live match callbacks during death-wall captures');
    assert.equal(typeof value.sleeping,'boolean');
    assert.ok(Number.isFinite(value.fall) && (phase==='falling' ? value.fall>0 && value.fall<1 : value.fall===1),'Valid falling/settled model pose');
    assert.equal(capture.companions.length,0);
    assert.equal(capture.skin.palette_valid,true,'Actual wall-death palette is valid');
    assert.equal(capture.skin.bones,18);
    assert.ok([18,54].includes(capture.skin.bindings));
    for (const field of ['poses','palette']) {
      assert.equal(capture.skin[field].length,18);
      for(const matrix of capture.skin[field]) vector(matrix,12,`${field} transform`);
    }
    vector(capture.skin.model_transform,12,'model transform');
    assert.equal(typeof capture.weapon_clear,'boolean');
    assert.ok(Number.isFinite(capture.weapon_withdrawal) && capture.weapon_withdrawal>=0 && capture.weapon_withdrawal<=1);
    const wall=value.wall, capsule=value.capsule, gun=value.weapon, vertices=value.vertices;
    assert.equal(wall.found,true,'The real map wall was found');
    assert.equal(wall.body_class,'StaticBody3D');
    assert.equal(wall.shape_class,'BoxShape3D');
    vector(wall.point,3,'wall point'); vector(wall.normal,3,'wall normal'); vector(wall.shape_size,3,'wall shape');
    vector(capture.actor_position,3,'actor position');
    assert.ok(Math.abs(wall.point[0]+8)<0.0001 && Math.abs(wall.normal[0]-1)<0.0001,'Expected west-wall face');
    assert.ok(wall.shape_size.every(value=>value>0));
    assert.equal(capsule.shape_class,'CapsuleShape3D');
    assert.ok(Math.abs(capsule.radius-0.32)<0.000001 && Math.abs(capsule.height-1.8)<0.000001,'Actual bot capsule dimensions');
    assert.ok(Math.abs(capsule.center_distance_m-0.326)<0.00001,'Bot capsule placement, not player viewmodel distance');
    assert.ok(Math.abs(capture.actor_position[0]-wall.point[0]-capsule.center_distance_m)<0.00001,'Capsule placement matches the captured actor');
    assert.ok(Math.abs(capsule.wall_margin_m-0.006)<0.00001,'Six millimetres of capsule wall clearance');
    count(capsule.overlaps,'capsule overlap count');
    vector(gun.bounds_position,3,'gun bounds position'); vector(gun.bounds_size,3,'gun bounds size');
    vector(gun.shape_size,3,'gun hull shape'); vector(gun.hull_transform,12,'gun hull transform');
    vector(gun.grip_error_m,2,'two hand-grip errors');
    assert.ok(gun.bounds_size.every(value=>value>0) && gun.grip_error_m.every(value=>value>=0));
    for(let axis=0;axis<3;axis++) assert.ok(Math.abs(gun.shape_size[axis]-gun.bounds_size[axis]-0.11)<0.000001,'Full padded weapon hull');
    count(gun.hull_overlaps,'weapon hull overlap count');
    assert.equal(typeof gun.connection_clear,'boolean');
    for(const field of ['body_count','weapon_count']) {count(vertices[field],field);assert.ok(vertices[field]>0,'Both body and weapon vertices sampled');}
    for(const field of ['body_min_wall_m','weapon_min_wall_m']) assert.ok(Number.isFinite(vertices[field]),`Finite ${field}`);
    assert.equal(typeof value.measurement,'string');
    // These are diagnostics, not a claim that existing corpses obey walls or
    // retain their grip. Keep problematic captures available for a later fix.
    return {name:capture.name,phase,sleeping:value.sleeping,weapon_clear:capture.weapon_clear,
      starting_withdrawal:value.starting_withdrawal,starting_cached_clear:value.starting_cached_clear,
      capsule_overlaps:capsule.overlaps,hull_overlaps:gun.hull_overlaps,connection_clear:gun.connection_clear,
      grip_error_m:gun.grip_error_m,body_min_wall_m:vertices.body_min_wall_m,weapon_min_wall_m:vertices.weapon_min_wall_m};
  });
}

function validateSleepStages(captures) {
  const stages=SLEEP_NAMES.map(name=>captures.find(capture=>capture.name===name));
  assert.ok(stages.every(Boolean),'All three corpse sleep stages are present');
  const [entry,hold,moved]=stages;
  for (const capture of stages) {
    const state=capture.sleep;
    assert.ok(state && typeof state.sleeping==='boolean','Actual corpse sleep state is reported');
    assert.ok(Number.isInteger(state.settle_ticks) && state.settle_ticks>=60 && state.settle_ticks<=180,'Sleep must settle within 60–180 actual process ticks');
    for (const field of ['process_calls','held_frames','skeleton_updates'])
      assert.ok(Number.isInteger(state[field]) && state[field]>=0,`Nonnegative ${field}`);
    assert.ok(Number.isFinite(state.corpse_time) && state.corpse_time>=0,'Finite corpse settling time');
    assert.equal(state.health,0,'A dead actor exercises the production callback');
    assert.equal(state.paused,true,'The match is paused before every render/capture');
    assert.ok(Number.isFinite(state.game_elapsed),'Finite match time is reported');
    assert.equal(state.game_elapsed,entry.sleep.game_elapsed,'No live match ticks run between captures');
    assert.equal(state.settle_ticks,entry.sleep.settle_ticks,'All stages refer to the same settling interval');
    assert.equal(capture.companions.length,0,'Only the corpse is visible in sleep stages');
    assert.equal(capture.skin.palette_valid,true,'Corpse palette matches the actual skeleton');
    assert.ok(typeof capture.skin.palette_rid==='string' && capture.skin.palette_rid.length>0,'An actual registered palette is reported');
    assert.equal(capture.skin.palette_rid,entry.skin.palette_rid,'The same registered palette survives sleep and wake');
    assert.equal(capture.weapon_clear,true,'The frozen and moved corpse weapon remains clear');
  }
  assert.equal(entry.sleep.sleeping,true,'The real callback reached sleep');
  assert.ok(entry.sleep.corpse_time>=1,'The corpse completed the one-second settling interval');
  assert.ok(entry.sleep.skeleton_updates>0,'Entry capture drains real pending skeleton updates');
  assert.equal(entry.sleep.process_calls,entry.sleep.settle_ticks,'Entry counts every actual settling callback');
  assert.equal(entry.sleep.held_frames,0);
  assert.equal(hold.sleep.sleeping,true,'The held corpse remains asleep');
  assert.equal(hold.sleep.held_frames,8,'Eight rendered hold frames were exercised');
  assert.equal(hold.sleep.process_calls,entry.sleep.process_calls+8,'The real callback runs during every held frame');
  assert.equal(hold.sleep.skeleton_updates,entry.sleep.skeleton_updates,'Sleeping emits no additional skeleton_updated signals');
  assert.equal(hold.sleep.corpse_time,entry.sleep.corpse_time,'Sleeping does not advance settling time');
  for (const field of ['build','actor_position','actor_yaw','weapon_clear','weapon_withdrawal'])
    assert.deepEqual(hold[field],entry[field],`Sleeping preserves ${field}`);
  for (const field of ['poses','palette','model_transform'])
    assert.deepEqual(hold.skin[field],entry.skin[field],`Sleeping preserves ${field}`);
  for (const field of ['quality','ssao','scale_3d','viewport_pixels','primitives','draw_calls'])
    assert.deepEqual(hold.render[field],entry.render[field],`Sleeping preserves rendered ${field}`);
  assert.equal(moved.sleep.sleeping,false,'Moving the corpse wakes animation');
  assert.equal(moved.sleep.held_frames,8);
  assert.equal(moved.sleep.process_calls,hold.sleep.process_calls+1,'Movement exercises one actual wake callback');
  assert.ok(moved.sleep.skeleton_updates>hold.sleep.skeleton_updates,'The wake callback produces another skeleton_updated signal');
  assert.ok(moved.sleep.corpse_time<entry.sleep.corpse_time,'Movement begins a fresh settling interval');
  assert.ok(Math.abs(moved.actor_position[0]-hold.actor_position[0]-0.2)<0.00001,'The corpse moves exactly 0.2 m along X');
  assert.deepEqual(moved.actor_position.slice(1),hold.actor_position.slice(1));
  assert.equal(moved.actor_yaw,hold.actor_yaw);
  return {held_frames:8,skeleton_updates_while_sleeping:0,
    skeleton_updates_on_wake:moved.sleep.skeleton_updates-hold.sleep.skeleton_updates,
    settle_ticks:entry.sleep.settle_ticks};
}

function compareSleepImages(captures,readImage) {
  const report=validateSleepStages(captures);
  const stages=SLEEP_NAMES.map(name=>captures.find(capture=>capture.name===name));
  const images=stages.map(capture=>readImage(capture.name));
  for (let i=0;i<images.length;i++) {
    const image=images[i];
    assert.deepEqual([image.width,image.height],stages[i].render.viewport_pixels,'Sleep screenshot dimensions match the rendered viewport');
    assert.deepEqual([image.width,image.height],[images[0].width,images[0].height]);
    assert.equal(image.data.length,image.width*image.height*4);
  }
  assert.ok(images[0].data.equals(images[1].data),'Sleep entry and hold pixels must be exactly equal');
  assert.ok(!images[1].data.equals(images[2].data),'The moved corpse must visibly update after waking');
  return {...report,entry_hold_pixel_exact:true,moved_pixels_changed:true};
}

function validateStages(captures) {
  assert.deepEqual(captures.map(capture=>capture.name),NAMES,'All single- and multi-rig stages captured in order');
  for(const capture of captures.filter(capture=>!DEATH_WALL_NAMES.includes(capture.name)))
    assert.equal(capture.death_wall,undefined,'Wall-death metadata is reserved for diagnostic stages');
  for (const team of ['ct','t']) {
    const poses=captures.filter(capture=>KEY_POSES.some(pose=>capture.name===team+'-'+pose));
    for (const key of ['poses','palette'])
      assert.equal(new Set(poses.map(capture=>JSON.stringify(capture.skin[key]))).size,6,`${team}: six distinct ${key}, not frozen animation`);
  }
  for (const capture of captures.filter(capture=>capture.name.includes('squad'))) {
    const skins=[capture.skin,...capture.companions.map(other=>other.skin)];
    assert.equal(skins.length,3);
    assert.equal(new Set(skins.map(skin=>skin.palette_rid)).size,3,'Separate renderer palettes for shared-mesh actors');
    assert.equal(new Set(skins.map(skin=>JSON.stringify(skin.palette))).size,3,'Distinct simultaneous skinning poses');
  }
  validateSleepStages(captures);
  validateDeathWallStages(captures);
}

function compareSkin(reference,candidate,name) {
  for (const skin of [reference,candidate]) {
    assert.equal(skin.palette_valid,true);
    assert.equal(skin.bones,18);
    assert.equal(skin.poses.length,18);
    assert.equal(skin.palette.length,18);
  }
  assert.equal(reference.bindings,18);
  assert.equal(candidate.bindings,54);
  for (const key of ['poses','palette','model_transform'])
    assert.deepEqual(candidate[key],reference[key],`${name}: same ${key}`);
}

function comparePair(reference, candidate, a, b) {
  assert.equal(candidate.name, reference.name);
  for (const key of ['build','actor_position','actor_yaw','weapon_clear','weapon_withdrawal'])
    assert.deepEqual(candidate[key], reference[key], `${reference.name}: same ${key}`);
  for (const key of ['quality','ssao','scale_3d','viewport_pixels','primitives'])
    assert.deepEqual(candidate.render[key], reference.render[key], `${reference.name}: same ${key}`);
  assert.equal(reference.render.quality, 'High');
  assert.equal(reference.render.ssao, true);
  assert.equal(reference.render.scale_3d, 1);
  assert.ok(candidate.render.draw_calls < reference.render.draw_calls, 'Actual rendered draw calls decrease');
  compareSkin(reference.skin,candidate.skin,reference.name);
  assert.deepEqual(candidate.sleep,reference.sleep,`${reference.name}: same corpse sleep metadata`);
  assert.deepEqual(candidate.death_wall,reference.death_wall,`${reference.name}: same wall-death diagnostics`);
  assert.equal(candidate.companions.length,reference.companions.length);
  for (let i=0; i<reference.companions.length; i++) {
    const a=reference.companions[i], b=candidate.companions[i];
    assert.deepEqual(b.position,a.position);
    assert.equal(b.yaw,a.yaw);
    compareSkin(a.skin,b.skin,reference.name+': companion '+i);
  }
  assert.deepEqual([a.width,a.height], [b.width,b.height]);
  assert.deepEqual([a.width,a.height], reference.render.viewport_pixels);
  assert.equal(a.data.length, a.width*a.height*4);
  assert.equal(b.data.length, a.data.length);
  let changedPixels = 0, maximum = 0;
  for (let offset=0; offset<a.data.length; offset+=4) {
    let changed = false;
    for (let channel=0; channel<4; channel++) {
      const delta = Math.abs(a.data[offset+channel]-b.data[offset+channel]);
      maximum = Math.max(maximum,delta);
      changed ||= delta > 0;
    }
    if (changed) changedPixels++;
  }
  // StandardMaterial vs equivalent shader can round a few colors by 1/255.
  // Edge/shape/LOD changes must not be hidden behind a broad image tolerance.
  assert.ok(maximum <= 1, `${reference.name}: maximum pixel difference ${maximum}/255`);
  assert.ok(changedPixels <= Math.ceil(a.width*a.height*0.001), `${reference.name}: ${changedPixels} changed pixels`);
  return {name:reference.name,draw_calls_saved:reference.render.draw_calls-candidate.render.draw_calls,
    primitives:reference.render.primitives,changed_pixels:changedPixels,maximum_channel_difference:maximum};
}

if (require.main === module) {
  const fs = require('node:fs'), path = require('node:path');
  const {PNG} = require('playwright-core/lib/utilsBundle');
  const root = path.resolve(process.argv[2] || path.join(__dirname,'../../artifacts'));
  const reviews = fs.readdirSync(root).filter(name=>name.startsWith('map-review-browser-'))
    .map(name=>path.join(root,name)).filter(dir=>fs.existsSync(path.join(dir,'captures.json')))
    .map(dir=>({dir,...JSON.parse(fs.readFileSync(path.join(dir,'captures.json'),'utf8'))}))
    .filter(review=>review.operator_motion);
  assert.equal(reviews.length,2,'Use an isolated artifact folder containing one reference/candidate motion pair');
  const reference=reviews.find(review=>!review.operator_surface), candidate=reviews.find(review=>review.operator_surface);
  assert.ok(reference && candidate);
  assert.deepEqual(candidate.engine, reference.engine, 'Same exact engine binaries');
  validateStages(reference.captures);
  validateStages(candidate.captures);
  const sleepReport={};
  for (const [label,review] of [['reference',reference],['candidate',candidate]])
    sleepReport[label]=compareSleepImages(review.captures,name=>PNG.sync.read(fs.readFileSync(path.join(review.dir,name+'.png'))));
  fs.writeFileSync(path.join(candidate.dir,'corpse-sleep-comparison.json'),JSON.stringify(sleepReport,null,2)+'\n');
  const report=reference.captures.map((capture,index)=>comparePair(capture,candidate.captures[index],
    PNG.sync.read(fs.readFileSync(path.join(reference.dir,capture.name+'.png'))),
    PNG.sync.read(fs.readFileSync(path.join(candidate.dir,capture.name+'.png')))));
  fs.writeFileSync(path.join(candidate.dir,'operator-comparison.json'),JSON.stringify(report,null,2)+'\n');
  console.log('OPERATOR_MOTION_COMPARISON: PASS',JSON.stringify(report));
  console.log('CORPSE_SLEEP_RENDER_COMPARISON: PASS',JSON.stringify(sleepReport));
  console.log('CORPSE_WALL_DIAGNOSTICS:',JSON.stringify(validateDeathWallStages(reference.captures)));
}

module.exports = {comparePair,validateStages,validateSleepStages,compareSleepImages,validateDeathWallStages,NAMES,DEATH_WALL_NAMES};
