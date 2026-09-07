'use strict';

// Offline full-map correctness comparison, not a benchmark or engine launcher.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {parseReport} = require('./reported-view');
const {METHODS, TOTALS, imageDifference, imageVariation} = require('./depth-copy-review');

const REPORT = parseReport(JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/reported-ct.json'), 'utf8')));
const STAGES = [
  ['reported-high', 'High'],
  ['reported-balanced', 'Balanced'],
  ['reported-performance', 'Performance'],
  ['reported-high-restored', 'High'],
  ['reported-high-resized', 'High'],
  ['reported-high-size-restored', 'High'],
  ['overview-high', 'High'],
  ['a-site-high', 'High'],
].map(([name, quality]) => ({name, quality,
  physical: name === 'reported-high-resized' ? [1600, 900] : REPORT.render.viewport,
  pixels: name === 'reported-high-resized' ? [1600, 900] : REPORT.render.viewport_pixels,
}));
const NAMES = STAGES.map(stage => stage.name);

function integer(value, minimum, label) {
  assert(Number.isSafeInteger(value) && value >= minimum, `${label}: integer >= ${minimum}`);
}

function vector(value, length, label) {
  assert(Array.isArray(value) && value.length === length && [...value].every(Number.isFinite), `${label}: finite vector`);
}

function near(value, expected, label, tolerance = 1e-6) {
  assert(Number.isFinite(value) && Math.abs(value - expected) <= tolerance, `${label}: expected ${expected}`);
}

function keys(value, expected, label) {
  assert(value && typeof value === 'object' && !Array.isArray(value), `${label}: object`);
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), `${label}: exact fields`);
}

function validateAudit(audit, label) {
  assert.equal(audit?.contexts, 1, `${label}: one owned WebGL2 context`);
  assert.equal(audit.canvas_id, 'canvas');
  assert.equal(audit.adds_driver_queries, false);
  assert.equal(audit.consumes_get_error, false, 'Separate boundary error drains');
  assert.match(audit.scope, /not uniquely backbuffer3d/);
  keys(audit.calls, METHODS, `${label} native calls`);
  keys(audit.totals, TOTALS, `${label} totals`);
  for (const group of [audit.calls, audit.totals]) {
    for (const [field, value] of Object.entries(group)) integer(value, 0, `${label} ${field}`);
  }
  for (const field of ['exceptions', 'incomplete', 'unknown_texture_allocations']) {
    assert.equal(audit.totals[field], 0, `${label}: no ${field}`);
  }
  assert.deepEqual(audit.incomplete_statuses, []);
  assert.equal(audit.incomplete_status_overflow, 0);
  assert.equal(audit.totals.checks, audit.calls.checkFramebufferStatus);
  assert.equal(audit.totals.complete, audit.totals.checks);
  assert.equal(audit.totals.blits, audit.calls.blitFramebuffer);
  assert.equal(audit.totals.texture_allocations, audit.totals.color_texture_allocations + audit.totals.depth_texture_allocations);
  assert.equal(audit.totals.texture_allocations,
    ['texImage2D', 'texImage3D', 'texStorage2D', 'texStorage3D', 'copyTexImage2D'].reduce((sum, field) => sum + audit.calls[field], 0));
  assert.equal(audit.totals.renderbuffer_allocations, audit.calls.renderbufferStorage + audit.calls.renderbufferStorageMultisample);
  assert.equal(audit.totals.attachments,
    ['framebufferTexture2D', 'framebufferTextureLayer', 'framebufferRenderbuffer'].reduce((sum, field) => sum + audit.calls[field], 0));
  keys(audit.multisample_samples, ['0', '1', '2', '4', '8', 'other'], `${label} MSAA histogram`);
  for (const value of Object.values(audit.multisample_samples)) integer(value, 0, `${label} MSAA samples`);
  assert.equal(Object.values(audit.multisample_samples).reduce((a, b) => a + b, 0), audit.calls.renderbufferStorageMultisample);
}

function validateErrors(value, label) {
  assert.equal(value?.drained, true, `${label}: native error drain completed`);
  assert.equal(value.context_lost, false, `${label}: no context loss`);
  assert.deepEqual(value.errors, [], `${label}: no native GL errors`);
  assert.equal(value.reads, 1, `${label}: actual native NO_ERROR read`);
}

function exactImage(a, b) {
  assert.deepEqual([a.width, a.height], [b.width, b.height], 'Matched PNG dimensions');
  assert(a.data instanceof Uint8Array && b.data instanceof Uint8Array, 'Complete RGBA arrays');
  assert.equal(a.data.length, a.width * a.height * 4);
  assert.equal(b.data.length, b.width * b.height * 4);
  const bytes = image => Buffer.from(image.data.buffer, image.data.byteOffset, image.data.byteLength);
  // Native byte comparison keeps the common exact case fast. On any mismatch,
  // report all changed pixels/channel deltas, with no visual-tolerance escape.
  return bytes(a).equals(bytes(b))
    ? {changed_pixels: 0, max_channel_delta: 0, absolute_channel_delta: 0}
    : imageDifference(a, b);
}

function decodeCapture(capture) {
  const png = Buffer.from(capture.png || '', 'base64');
  assert(png.length >= 24 && png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])), 'Actual PNG readback');
  return require('playwright-core/lib/utilsBundle').PNG.sync.read(png);
}

function validateRender(capture, stage) {
  const render = capture.render;
  assert.equal(render?.quality, stage.quality);
  assert.equal(render.ssao, stage.quality === 'High');
  assert.deepEqual(render.viewport, stage.physical, 'Actual physical Window dimensions');
  assert.deepEqual(render.viewport_pixels, stage.pixels, 'Actual drawable dimensions');
  const [width, height] = stage.physical;
  const cap = stage.quality === 'Balanced' ? 1920 * 1080 : 1280 * 720;
  const scale = stage.quality === 'High' ? 1 : Math.min(1, Math.sqrt(cap / (width * height)));
  near(render.scale_3d, scale, 'Actual quality-dependent scale');
  if (stage.quality === 'High') assert.equal(render.scale_3d, 1, 'High preserves full resolution');
  assert.deepEqual(render.render_3d, stage.pixels.map(size => Math.max(1, Math.trunc(size * render.scale_3d))), 'Actual 3D target dimensions');
  vector(render.logical_size, 2, 'Logical viewport size');
  assert(render.logical_size.every(value => value > 0));
  integer(render.draw_calls, 1, 'Actual total render draws');
  integer(render.primitives, 1, 'Actual rendered primitives');
  assert.equal(capture.msaa_3d, stage.quality === 'Performance' ? 0 : 1, 'Actual MSAA disabled/2x state');
  const window = capture.window;
  assert.equal(window?.class, 'Window', 'Production root Window, not an isolated SubViewport');
  assert.deepEqual(window.size, stage.physical);
  assert.deepEqual(window.canvas_size, stage.physical);
  assert.equal(window.root_3d_enabled, true);
  assert.equal(window.use_xr, false);
  assert.equal(window.subviewports, 0);
}

function validateCamera(capture, stage) {
  const camera = capture.camera;
  assert.equal(camera?.mode, 'player', 'Actual player camera and attached viewmodel');
  assert.equal(camera.top_level, true, 'Exact reported basis is not reconstructed from player Euler angles');
  assert.equal(camera.current, true);
  vector(camera.transform, 12, 'Raw camera transform');
  vector(camera.position_xyz, 3, 'Adjusted camera position');
  assert(Array.isArray(camera.basis) && camera.basis.length === 3, 'Adjusted camera basis');
  camera.basis.forEach(column => vector(column, 3, 'Adjusted basis column'));
  for (const field of ['fov_degrees', 'near', 'far', 'keep_aspect']) near(camera[field], REPORT.camera[field], `Reported lens ${field}`);
  const columns = camera.basis;
  const dot = (a, b) => a.reduce((sum, value, index) => sum + value * b[index], 0);
  for (let column = 0; column < 3; column++) {
    near(dot(columns[column], columns[column]), 1, 'Orthonormal adjusted camera basis', 2e-6);
    for (let other = column + 1; other < 3; other++) near(dot(columns[column], columns[other]), 0, 'Orthogonal adjusted camera basis', 2e-6);
  }
  const [a, b, c] = columns;
  near(a[0] * (b[1] * c[2] - b[2] * c[1]) + a[1] * (b[2] * c[0] - b[0] * c[2]) + a[2] * (b[0] * c[1] - b[1] * c[0]),
    1, 'Right-handed adjusted camera basis', 2e-6);
  camera.position_xyz.forEach((value, axis) => near(value, camera.transform[9 + axis], 'Adjusted/raw camera position', 2e-6));
  if (stage.name.startsWith('reported-')) {
    const expected = [...REPORT.camera.basis.flat(), ...REPORT.camera.position_xyz];
    // Camera3D disables inherited scale: native get_global_transform() already
    // orthonormalizes before get_camera_transform() does so again. Bound that
    // float32 roundoff; matched engines/restored stages must still be exact.
    expected.forEach((value, index) => near(camera.transform[index], Math.fround(value), 'Native reported camera', 2e-6));
    REPORT.camera.basis.flat().forEach((value, index) => near(camera.basis.flat()[index], value, 'Adjusted reported camera', 2e-6));
  } else {
    const [at, target] = stage.name === 'overview-high'
      ? [[1, 1.65, -33], [1.5, 1.6, -18]] : [[29, 4.05, -29], [36, 3.5, -14]];
    const normalize = value => value.map(component => component / Math.hypot(...value));
    const z = normalize(at.map((value, axis) => value - target[axis]));
    const x = normalize([z[2], 0, -z[0]]);
    const y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]];
    [...x, ...y, ...z, ...at].forEach((value, index) => near(camera.transform[index], value, 'Pinned extra map view', 2e-6));
  }
}

function validateScene(capture, stage) {
  const environment = capture.environment;
  assert.equal(environment?.background_mode, 2, 'Real procedural sky environment');
  assert.equal(environment.sky_class, 'Sky');
  assert.equal(environment.sky_material_class, 'ProceduralSkyMaterial');
  assert.equal(environment.tonemap_mode, 2, 'Production filmic tonemapping');
  near(environment.tonemap_exposure, 0.98, 'Filmic exposure');
  assert.equal(environment.fog_enabled, true);
  near(environment.fog_density, 0.0018, 'Fog density');
  near(environment.fog_sky_affect, 0.18, 'Sky fog');
  assert.equal(environment.ssao_enabled, stage.quality === 'High');
  near(environment.ssao_radius, 1.3, 'SSAO radius');
  assert(Number.isFinite(environment.ssao_intensity) && environment.ssao_intensity > 0, 'Nonzero SSAO intensity');
  near(environment.ambient_energy, 0.48, 'Production ambient energy');
  vector(environment.ambient_color, 4, 'Ambient color');
  vector(environment.fog_light_color, 4, 'Fog color');
  keys(environment.sky_colors, ['top', 'horizon', 'ground_bottom', 'ground_horizon'], 'Procedural sky colors');
  Object.values(environment.sky_colors).forEach(value => vector(value, 4, 'Sky color'));
  assert(Array.isArray(capture.shadows) && capture.shadows.length === 1, 'One production directional sun');
  const shadow = capture.shadows[0], high = stage.quality === 'High';
  assert.equal(shadow.enabled, true, 'Shadows remain enabled at every preset');
  assert.equal(shadow.mode, high ? 2 : 1, 'Four/two directional shadow splits');
  near(shadow.distance, high ? 110 : stage.quality === 'Balanced' ? 70 : 50, 'Actual shadow distance');
  assert.equal(shadow.blend_splits, high);
  near(shadow.bias, 0.035, 'Unchanged shadow bias');
  vector(shadow.transform, 12, 'Sun transform');
  const hud = capture.hud;
  assert.equal(hud?.visible, true, 'Production HUD is visible');
  assert.equal(hud.menu_visible, false);
  assert.equal(hud.diagnostics, false);
  assert.equal(hud.manual_redraws, 6, 'One explicit ordinary HUD redraw per observed frame');
  vector(hud.size, 2, 'Actual HUD layout size');
  hud.size.forEach((value, axis) => near(value, capture.render.logical_size[axis], 'HUD fits logical viewport'));
  const gun = capture.viewmodel;
  assert.equal(gun?.visible, true, 'Visible production first-person weapon');
  assert.equal(gun.camera_child, true);
  assert.equal(gun.slot, 0);
  assert(typeof gun.gun_name === 'string' && gun.gun_name.length > 0, 'Actual viewmodel resource name');
  for (const field of ['held_local', 'held_world', 'gun_local']) vector(gun[field], 12, `Viewmodel ${field}`);
  vector(gun.bounds, 6, 'Complete viewmodel bounds');
  assert(gun.bounds.slice(3).every(value => value > 0), 'Nonempty complete viewmodel hull');
  assert.equal(gun.clear, true);
  assert.equal(gun.withdrawal, 0, 'Unwithdrawn fixed viewmodel');
  const parent = capture.camera.transform, local = gun.held_local;
  for (let column = 0; column < 4; column++) for (let row = 0; row < 3; row++) {
    let expected = column === 3 ? parent[9 + row] : 0;
    for (let axis = 0; axis < 3; axis++) expected += parent[axis * 3 + row] * local[column * 3 + axis];
    near(gun.held_world[column * 3 + row], expected, 'Viewmodel remains camera-relative', 2e-5);
  }
  const state = capture.state;
  assert.equal(state?.paused, false, 'Ordinary live HUD while callbacks are explicitly disabled');
  assert.equal(state.game_elapsed, 0);
  assert.equal(state.phase, 'LIVE');
  assert.equal(state.phase_left, 100);
  for (const field of ['silent_test', 'muted', 'process_disabled', 'physics_disabled', 'input_disabled', 'poses_unchanged', 'ai_unchanged']) {
    assert.equal(state[field], true, `Frozen fixture ${field}`);
  }
  assert.equal(state.mouse_captured, false);
  assert.equal(state.total_bots, 9);
  assert.deepEqual(state.operators, REPORT.operators, 'Reported counts with explicitly staged actor positions');
  assert.equal(state.sleeping_skeleton_updates, 0);
  assert.equal(state.skeleton_updates, 0, 'No rig palette updates during captures');
  for (const field of ['poses_sha256', 'ai_sha256']) assert.match(state[field], /^[a-f0-9]{64}$/, `Actual frozen ${field}`);
  vector(state.player_position, 3, 'Staged player position');
  assert(Number.isFinite(state.player_yaw) && Number.isFinite(state.pitch), 'Finite staged player orientation');
  state.player_position.forEach((value, axis) => near(value, capture.camera.transform[9 + axis] - (axis === 1 ? 1.62 : 0), 'Player aligned with staged camera'));
  near(state.player_yaw, Math.atan2(capture.camera.transform[6], capture.camera.transform[8]), 'Player yaw aligned with camera');
  near(state.pitch, Math.asin(-capture.camera.transform[7]), 'Player pitch aligned with camera');
  const world = capture.world;
  for (const field of ['static_bodies', 'mesh_instances', 'multimesh_instances']) integer(world?.[field], 1, `Actual world ${field}`);
  assert(world.batching && Object.keys(world.batching).length > 0, 'Actual production batching metadata');
}

function validateReview(review, readImage = decodeCapture) {
  assert.equal(review?.engine_map_review, true);
  assert.equal(review.staged, true, 'Explicit staged scene, not a match replay');
  assert.equal(typeof review.expected_patch, 'boolean');
  for (const field of ['js_sha256', 'wasm_sha256']) assert.match(review.engine?.[field] || '', /^[a-f0-9]{64}$/, `Actual exported ${field}`);
  assert.equal(review.summary?.stages, NAMES.length);
  assert.equal(review.summary.failures, 0);
  assert.deepEqual(review.summary.failure_labels, []);
  assert.equal(review.summary.setup_frames, 3);
  assert.equal(review.summary.steady_frames, 3);
  assert.match(review.summary.measurement, /not gameplay or FPS/);
  assert.equal(review.summary.reported_source_build, REPORT.build);
  assert.deepEqual(review.summary.reported_operators, REPORT.operators);
  const {mode, ...sourceCamera} = review.summary.reported_camera || {};
  if (mode !== undefined) assert.equal(mode, 'player');
  assert.deepEqual(sourceCamera, REPORT.camera, 'Exact reported input lens/basis, not rounded telemetry');
  integer(review.summary.checks, 1, 'Fixture check count');
  assert(Array.isArray(review.captures));
  assert.deepEqual(review.captures.map(capture => capture.name), NAMES, 'Complete exact ordered eight-stage matrix');
  const images = [];
  review.captures.forEach((capture, index) => {
    const stage = STAGES[index];
    assert.equal(capture.name, stage.name);
    assert(typeof capture.build === 'string' && capture.build.length > 0);
    assert.match(capture.fixture, /not .*FPS/);
    assert.equal(capture.renderer, 'gl_compatibility');
    assert.equal(capture.setup_frames, 3);
    assert.equal(capture.steady_frames, 3);
    assert.equal(capture.failures, 0);
    integer(capture.checks, 1, 'Per-stage actual check count');
    validateRender(capture, stage);
    validateCamera(capture, stage);
    validateScene(capture, stage);
    for (const phase of ['setup', 'steady']) {
      const draws = capture[`${phase}_visible_draw_calls`];
      assert(Array.isArray(draws) && draws.length === 3, 'Three actual visible-frame samples');
      draws.forEach(value => integer(value, 1, 'Actual visible draw submissions'));
      validateAudit(capture[`${phase}_audit`], `${stage.name} ${phase}`);
    }
    assert(capture.steady_visible_draw_calls.every(value => value === capture.steady_visible_draw_calls[0]), 'Steady visible draw counts unchanged');
    for (const phase of ['before', 'setup', 'steady', 'final']) validateErrors(capture[`${phase}_errors`], `${stage.name} ${phase}`);
    // This audit covers every framebuffer, including incremental sky cubemap
    // filtering, which can reattach existing color textures without allocating.
    // compareReviews still requires identical original/patched attachment calls.
    for (const field of ['texture_allocations', 'renderbuffer_allocations']) {
      assert.equal(capture.steady_audit.totals[field], 0, `No steady ${field}`);
    }
    if (stage.quality === 'High' && !review.expected_patch) assert(capture.steady_audit.totals.checks >= 3, 'Original High still requests the depth backbuffer');
    const first = review.captures[0];
    for (const field of ['world', 'build']) assert.deepEqual(capture[field], first[field], `Unchanged ${field} throughout lifecycle`);
    for (const field of ['poses_sha256', 'ai_sha256']) assert.equal(capture.state[field], first.state[field], `Unchanged actual ${field}`);
    const image = readImage(capture);
    assert.deepEqual([image?.width, image?.height], stage.pixels, 'Actual full drawable PNG dimensions');
    const variation = imageVariation(image);
    assert(variation.colors_at_least >= 8 && variation.channel_span >= 8, 'Nonblank actual full-map image');
    images.push(image);
  });
  assert.equal(review.summary.checks, review.captures.reduce((sum, capture) => sum + capture.checks, 4), 'All stage checks and four outer fixture checks recorded');
  const first = review.captures[0];
  const restorations = [];
  for (const index of [3, 5]) {
    for (const field of ['camera', 'environment', 'shadows', 'hud', 'viewmodel', 'state', 'render']) {
      assert.deepEqual(review.captures[index][field], first[field], `Restored High ${field} exactly unchanged`);
    }
    const difference = exactImage(images[0], images[index]);
    // Only same-engine target recreation permits sparse one-LSB variance.
    // Quality-only restoration and every original/patched pair stay exact.
    const resized = index === 5;
    const allowedPixels = resized ? Math.floor(images[0].width * images[0].height / 100000) : 0;
    if (resized) {
      assert(difference.max_channel_delta <= 1, 'Same-engine resize restore exceeds one LSB');
      assert(difference.changed_pixels <= allowedPixels, 'Same-engine resize restore exceeds 0.001% changed pixels');
    } else {
      assert.equal(difference.changed_pixels, 0, 'Restoring High quality restores exact complete image');
    }
    restorations.push({name: review.captures[index].name, ...difference,
      allowed_changed_pixels: allowedPixels, allowed_max_channel_delta: resized ? 1 : 0});
  }
  for (const index of [1, 2, 6, 7]) assert(exactImage(images[0], images[index]).changed_pixels > 0,
    'Quality/extra camera stages produce distinct visible images (not isolated SSAO proof)');
  return {stages: NAMES.length, restored_images_exact: restorations.every(value => value.changed_pixels === 0),
    same_engine_restorations: restorations,
    limitations: 'Full-map staged root-Window correctness; no gameplay, target-driver, bandwidth or FPS claim'};
}

function metadata(capture) {
  const result = {...capture};
  for (const field of ['png', 'checks', 'failures', 'setup_audit', 'steady_audit',
    'before_errors', 'setup_errors', 'steady_errors', 'final_errors']) delete result[field];
  return result;
}

function compareReviews(baseline, patched, readBaseline = decodeCapture, readPatched = decodeCapture) {
  assert.equal(baseline?.expected_patch, false);
  assert.equal(patched?.expected_patch, true);
  assert.notEqual(baseline.engine?.wasm_sha256, patched.engine?.wasm_sha256, 'Different verified original/patched Wasm');
  const checks = [validateReview(baseline, readBaseline), validateReview(patched, readPatched)];
  const pairs = baseline.captures.map((a, index) => {
    const b = patched.captures[index], high = STAGES[index].quality === 'High';
    assert.deepEqual(metadata(a), metadata(b), `${a.name}: exact scene, camera, HUD, weapon, settings and draw-count metadata`);
    const expected = high ? -3 : 0;
    for (const [group, names] of [['calls', METHODS], ['totals', TOTALS]]) {
      const changed = group === 'calls' ? ['checkFramebufferStatus', 'blitFramebuffer'] : ['checks', 'complete', 'blits', 'depth_blits', 'stencil_blits'];
      for (const field of names) assert.equal(b.steady_audit[group][field] - a.steady_audit[group][field],
        changed.includes(field) ? expected : 0, `${a.name}: expected steady ${group}.${field} delta`);
    }
    assert.deepEqual(a.steady_audit.multisample_samples, b.steady_audit.multisample_samples);
    const difference = exactImage(readBaseline(a), readPatched(b));
    assert.equal(difference.changed_pixels, 0, `${a.name}: original/patched PNG mismatch ${JSON.stringify(difference)}`);
    return {name: a.name, ...difference, steady_depth_blits_delta: expected, steady_checks_delta: expected,
      setup_allocations: [a, b].map(capture => ({textures: capture.setup_audit.totals.texture_allocations,
        depth_textures: capture.setup_audit.totals.depth_texture_allocations, framebuffers: capture.setup_audit.calls.createFramebuffer}))};
  });
  return {label: 'Full-map root-Window images and steady native-call correctness; not gameplay or FPS proof', checks, pairs,
    setup_limit: 'Setup allocations are recorded, not forced to microfixture deltas: root buffers, sky and shadow reconfiguration also allocate.'};
}

if (require.main === module) {
  try {
    const args = process.argv.slice(2);
    assert(args.length === 4 && args[0] === '--baseline' && args[2] === '--patched',
      'Usage: node courtyard/tests/engine-map-review.js --baseline DIR --patched DIR');
    const directories = [path.resolve(args[1]), path.resolve(args[3])];
    const reviews = directories.map(directory => JSON.parse(fs.readFileSync(path.join(directory, 'captures.json'), 'utf8')));
    const {PNG} = require('playwright-core/lib/utilsBundle');
    const readers = directories.map(directory => capture => PNG.sync.read(fs.readFileSync(path.join(directory, `${capture.name}.png`))));
    console.log('ENGINE_MAP_REVIEW_COMPARISON: PASS', JSON.stringify(compareReviews(...reviews, ...readers)));
  } catch (error) { console.error(`ENGINE_MAP_REVIEW_COMPARISON: FAIL: ${error.message}`); process.exitCode = 1; }
}

module.exports = {NAMES, STAGES, REPORT, validateReview, compareReviews, exactImage};
