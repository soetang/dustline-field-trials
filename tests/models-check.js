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
