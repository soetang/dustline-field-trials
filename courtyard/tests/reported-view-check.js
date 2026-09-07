'use strict';

// Pure input-contract checks; no engine, renderer, compiler or browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {parseReport, loadReport} = require('./reported-view');
let checks = 0;
function check(fn) { fn(); checks++; }

function report() {
  // Synthetic valid full-telemetry shape, not an invented exact player replay.
  return {
    build: 'courtyard-0.4.13-camera-telemetry',
    camera: {mode: 'player', position_xyz: [-3.955854, 1.620625, -33.817787],
      basis: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], fov_degrees: 80, near: 0.045, far: 200, keep_aspect: 1},
    render: {quality: 'High', ssao: true, scale_3d: 1, viewport: [2208, 1242],
      viewport_pixels: [2208, 1242], render_3d: [2208, 1242], draw_calls: 602, primitives: 133840},
    operators: {alive: 2, dead: 7, sleeping: 7},
    recent_live_frames: {samples: 1800, mean_fps: 19.39},
    seed: 512, position: 'unrelated player position',
  };
}

function rejects(change, field) {
  check(() => {
    const input = report();
    change(input);
    assert.throws(() => parseReport(input), error => error instanceof TypeError && error.message.includes(field));
  });
}

check(() => {
  const input = report(), before = structuredClone(input), result = parseReport(input);
  assert.deepEqual(input, before, 'source untouched');
  assert.deepEqual(Object.keys(result), ['camera', 'render', 'operators', 'build']);
  const {mode, ...camera} = input.camera;
  assert.deepEqual(result.camera, camera);
  const {draw_calls, primitives, ...render} = input.render;
  assert.deepEqual(result.render, render);
  assert.deepEqual(result.operators, input.operators);
  assert.equal(result.build, input.build);
  input.camera.basis[0][0] = 99;
  input.camera.position_xyz[0] = 99;
  input.render.viewport[0] = 99;
  input.render.viewport_pixels[0] = 99;
  input.render.render_3d[0] = 99;
  input.operators.sleeping = 0;
  assert.deepEqual(result, parseReport(before), 'all returned nested arrays/objects are detached');
});

for (const input of [null, undefined, [], 3, 'report']) {
  check(() => assert.throws(() => parseReport(input), /report must be an object/));
}
for (const field of ['camera', 'render', 'operators', 'build']) rejects(input => { delete input[field]; }, field);
for (const field of ['position_xyz', 'basis', 'fov_degrees', 'near', 'far', 'keep_aspect'])
  rejects(input => { delete input.camera[field]; }, 'camera.' + field);
for (const field of ['quality', 'ssao', 'scale_3d', 'viewport', 'viewport_pixels', 'render_3d'])
  rejects(input => { delete input.render[field]; }, 'render.' + field);
for (const field of ['alive', 'dead', 'sleeping'])
  rejects(input => { delete input.operators[field]; }, 'operators.' + field);

for (const value of [NaN, Infinity, -Infinity, '1', null, true]) {
  rejects(input => { input.camera.position_xyz[0] = value; }, 'camera.position_xyz');
  rejects(input => { input.camera.basis[1][1] = value; }, 'camera.basis');
  rejects(input => { input.camera.fov_degrees = value; }, 'camera.fov_degrees');
  rejects(input => { input.operators.alive = value; }, 'operators.alive');
}
rejects(input => { input.camera.position_xyz = [1, 2]; }, 'camera.position_xyz');
rejects(input => { input.camera.position_xyz = new Array(3); }, 'camera.position_xyz');
rejects(input => { input.camera.basis = [[1, 0, 0], [0, 1, 0]]; }, 'camera.basis');
rejects(input => { input.camera.basis[0] = [1, 0]; }, 'camera.basis');
rejects(input => { input.camera.basis[0] = [0, 0, 0]; }, 'unit length');
rejects(input => { input.camera.basis[0] = [2, 0, 0]; }, 'unit length');
rejects(input => { input.camera.basis[1] = [0.1, Math.sqrt(0.99), 0]; }, 'orthogonal');
rejects(input => { input.camera.basis[2] = [0, 0, -1]; }, 'right-handed');
rejects(input => { input.camera.basis[1] = [1, 0, 0]; }, 'orthogonal');
check(() => {
  const input = report();
  input.camera.basis = [[0, 0, -1], [0, 1, 0], [1, 0, 0]];
  assert.deepEqual(parseReport(input).camera.basis, input.camera.basis);
  input.camera.basis[0][2] = -1.0000001; // Imported float drift: accepted, never normalized.
  assert.deepEqual(parseReport(input).camera.basis, input.camera.basis);
});
for (const value of [0, 180, -3]) rejects(input => { input.camera.fov_degrees = value; }, 'camera.fov_degrees');
for (const value of [0, -0.1, 200, 201, NaN, Infinity]) rejects(input => { input.camera.near = value; }, 'camera.near');
for (const value of [0, -1, 0.045, NaN, Infinity]) rejects(input => { input.camera.far = value; }, 'camera.');
for (const value of [-1, 2, 0.5, '1', true, NaN]) rejects(input => { input.camera.keep_aspect = value; }, 'camera.keep_aspect');
for (const value of [1, 179]) check(() => {
  const input = report();
  input.camera.fov_degrees = value;
  input.camera.keep_aspect = 0;
  assert.equal(parseReport(input).camera.fov_degrees, value);
});

rejects(input => { input.render.quality = 'Balanced'; }, 'render.quality');
rejects(input => { input.render.ssao = false; }, 'render.ssao');
rejects(input => { input.render.ssao = 1; }, 'render.ssao');
for (const value of [0.5, 0, '1', NaN]) rejects(input => { input.render.scale_3d = value; }, 'render.scale_3d');
for (const field of ['viewport', 'viewport_pixels', 'render_3d']) {
  for (const value of [[0, 720], [1280, -1], [1280.5, 720], [1280, 2161], [Infinity, 720], [1280], '1280x720'])
    rejects(input => { input.render[field] = value; }, 'render.' + field);
}
rejects(input => { input.render.viewport = [4097, 2160]; }, 'render.viewport');
rejects(input => { input.render.viewport_pixels = [3841, 2160]; }, 'render.viewport_pixels');
rejects(input => { input.render.render_3d = [3841, 2160]; }, 'render.render_3d');
rejects(input => { input.render.render_3d = [1280, 720]; }, 'must equal');
rejects(input => { input.render.viewport = [1920, 1080]; }, 'must fit');
check(() => {
  const input = report();
  input.render.viewport = [4096, 2160];
  input.render.viewport_pixels = [3840, 2160];
  input.render.render_3d = [3840, 2160];
  assert.deepEqual(parseReport(input).render.viewport, [4096, 2160], 'physical letterboxing does not lower render scale');
});
for (const value of [-1, 0.5, 10]) rejects(input => { input.operators.dead = value; }, 'operators.dead');
rejects(input => { input.operators.alive = 3; }, 'exactly nine');
rejects(input => { input.operators.sleeping = 6; }, 'must equal');
for (const dead of [0, 9]) check(() => {
  const input = report();
  input.operators = {alive: 9 - dead, dead, sleeping: dead};
  assert.deepEqual(parseReport(input).operators, input.operators);
});
for (const value of ['', '  ', 13, 'x\ny', 'x'.repeat(129)]) rejects(input => { input.build = value; }, 'build');
check(() => {
  const input = report();
  input.unrelated = {bad: NaN, nested: ['ignored']};
  input.camera.extra = Infinity;
  input.render.draw_calls = 'not needed';
  input.operators.extra = 'ignored';
  assert.deepEqual(parseReport(input), parseReport(report()), 'unrelated telemetry does not enter the fixture');
});

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'courtyard-reported-view-'));
try {
  const filename = path.join(temporary, 'report with spaces.json');
  fs.writeFileSync(filename, JSON.stringify(report()));
  check(() => assert.deepEqual(loadReport(filename), parseReport(report())));
  fs.writeFileSync(filename, '{not json');
  check(() => assert.throws(() => loadReport(filename), SyntaxError));
  fs.writeFileSync(filename, JSON.stringify({...report(), operators: {alive: 3, dead: 7, sleeping: 7}}));
  check(() => assert.throws(() => loadReport(filename), /exactly nine/));
} finally {
  fs.rmSync(temporary, {recursive: true, force: true});
}

console.log(`REPORTED_VIEW: ${checks}/${checks} passed; strict camera/High/render/count validation; no engine or GPU`);
