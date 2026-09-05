'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
for (const team of ['ct', 't']) {
  const data = fs.readFileSync(`assets/models/${team}_operator.glb`);
  assert.equal(data.readUInt32LE(0), 0x46546c67); assert.equal(data.readUInt32LE(4), 2);
  assert.equal(data.readUInt32LE(8), data.length); assert.ok(data.length < 600000);
  const gltf = JSON.parse(data.toString('utf8', 20, 20 + data.readUInt32LE(12)));
  assert.ok(!gltf.extensionsRequired?.includes('KHR_draco_mesh_compression'), 'Runtime must not need a Draco decoder');
  assert.equal(gltf.materials.length, 2);
  let triangles = 0, draws = 0;
  for (const mesh of gltf.meshes) for (const primitive of mesh.primitives) {
    assert.ok(primitive.attributes.COLOR_0 !== undefined, 'Missing team/equipment colours');
    assert.ok(primitive.attributes.NORMAL !== undefined);
    triangles += gltf.accessors[primitive.indices].count / 3; draws++;
  }
  assert.equal(draws, 4); assert.ok(triangles < 10000);
  for (const name of ['leg_l', 'leg_r']) {
    const node = gltf.nodes.find(n => n.name.split('.')[0] === name);
    assert.ok(node?.children?.length); assert.ok(Math.abs(node.translation[1] - .92) < .001, 'Leg pivot must be at the hip');
  }
  const root = gltf.nodes.find(n => n.name === `${team}_operator`);
  assert.ok(Math.abs(root.translation[1] + 1.05) < .001, 'Model and renderer waist origins disagree');
  console.log(`${team.toUpperCase()} operator verified: ${triangles} triangles, ${draws} draws, ${(data.length / 1024).toFixed(0)} KiB, hip pivots and vertex colours.`);
}
for (const weapon of ['m4','ak','awp','deagle']) {
  const data=fs.readFileSync(`assets/models/view_${weapon}.glb`);
  assert.equal(data.readUInt32LE(0),0x46546c67);assert.equal(data.readUInt32LE(8),data.length);
  assert.ok(data.length<850000,'First-person assets must stay small');
  const gltf=JSON.parse(data.toString('utf8',20,20+data.readUInt32LE(12)));
  assert.ok(!gltf.images?.length && !gltf.textures?.length,'Weapon colours should not require additional downloads');
  assert.ok(!gltf.extensionsRequired?.length,'No additional mesh decoder should be needed');
  const primitives=gltf.meshes.flatMap(m=>m.primitives);
  const triangles=primitives.reduce((n,p)=>n+gltf.accessors[p.indices].count/3,0);
  assert.ok(primitives.length<=8 && triangles<16000,'First-person draw and triangle budgets');
  for(const p of primitives)assert.ok(p.attributes.COLOR_0!==undefined && p.attributes.NORMAL!==undefined);
  for(const name of ['weapon_body','magazine','bolt','support_hand','trigger_hand','muzzle'])
    assert.ok(gltf.nodes.some(n=>n.name.split('.')[0]===name),`Missing ${weapon} animation pivot: ${name}`);
  const muzzle=gltf.nodes.find(n=>n.name.split('.')[0]==='muzzle').translation;
  assert.ok(Math.abs(muzzle[0])<.001 && muzzle[2]<-.3 && muzzle[2]>-1.4,'Muzzle must face forward in glTF/game coordinates');
  console.log(`${weapon.toUpperCase()} view model verified: ${triangles} triangles, ${primitives.length} draws, ${(data.length/1024).toFixed(0)} KiB, moving parts and texture-free colours.`);
}
