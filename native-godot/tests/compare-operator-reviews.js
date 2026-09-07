'use strict';

// Offline artifact comparison. Never launches a browser or touches host input.
const assert = require('node:assert/strict');
const NAMES=[...['ct','t'].flatMap(team=>['walk-first','walk-next','aim-high','reload','falling','fallen'].map(pose=>`${team}-${pose}`)),
  'ct-squad','ct-squad-edge','ct-squad-distance'];

function validateStages(captures) {
  assert.deepEqual(captures.map(capture=>capture.name),NAMES,'All single- and multi-rig stages captured in order');
  for (const team of ['ct','t']) {
    const poses=captures.filter(capture=>capture.name.startsWith(team+'-') && !capture.name.includes('squad'));
    for (const key of ['poses','palette'])
      assert.equal(new Set(poses.map(capture=>JSON.stringify(capture.skin[key]))).size,6,`${team}: six distinct ${key}, not frozen animation`);
  }
  for (const capture of captures.filter(capture=>capture.name.includes('squad'))) {
    const skins=[capture.skin,...capture.companions.map(other=>other.skin)];
    assert.equal(skins.length,3);
    assert.equal(new Set(skins.map(skin=>skin.palette_rid)).size,3,'Separate renderer palettes for shared-mesh actors');
    assert.equal(new Set(skins.map(skin=>JSON.stringify(skin.palette))).size,3,'Distinct simultaneous skinning poses');
  }
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
  const report=reference.captures.map((capture,index)=>comparePair(capture,candidate.captures[index],
    PNG.sync.read(fs.readFileSync(path.join(reference.dir,capture.name+'.png'))),
    PNG.sync.read(fs.readFileSync(path.join(candidate.dir,capture.name+'.png')))));
  fs.writeFileSync(path.join(candidate.dir,'operator-comparison.json'),JSON.stringify(report,null,2)+'\n');
  console.log('OPERATOR_MOTION_COMPARISON: PASS',JSON.stringify(report));
}

module.exports = {comparePair,validateStages,NAMES};
