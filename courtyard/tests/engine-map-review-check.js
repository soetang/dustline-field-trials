'use strict';

// Synthetic offline contract tests. These never instantiate the game or prove
// that the actual map rendered; the separately captured PNG/GL evidence does.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {METHODS, TOTALS} = require('./depth-copy-review');
const {NAMES, STAGES, REPORT, validateReview, compareReviews, exactImage} = require('./engine-map-review');
let checks = 0;
function check(callback) { callback(); checks++; }
const identity = [1, 0, 0, 0, 1, 0, 0, 0, 1];
const errorDrain = {errors: [], drained: true, context_lost: false, reads: 1};
const imageCache = new Map();

function imageFor(capture) {
  const quality = capture.render.quality;
  const variant = capture.name === 'overview-high' ? 3 : capture.name === 'a-site-high' ? 4
    : quality === 'Balanced' ? 1 : quality === 'Performance' ? 2 : 0;
  const [width, height] = capture.render.viewport_pixels;
  const key = `${width}:${height}:${variant}`;
  if (!imageCache.has(key)) {
    const data = Buffer.alloc(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const at = (y * width + x) * 4;
      data[at] = 40 + x % 24;
      data[at + 1] = 80 + y % 32;
      data[at + 2] = 100 + variant;
      data[at + 3] = 255;
    }
    imageCache.set(key, {width, height, data});
  }
  return imageCache.get(key);
}

function cameraTransform(name) {
  if (name.startsWith('reported-')) return [...REPORT.camera.basis.flat(), ...REPORT.camera.position_xyz];
  const [at, target] = name === 'overview-high'
    ? [[1, 1.65, -33], [1.5, 1.6, -18]] : [[29, 4.05, -29], [36, 3.5, -14]];
  const normalize = v => v.map(x => x / Math.hypot(...v));
  const z = normalize(at.map((value, axis) => value - target[axis]));
  const x = normalize([z[2], 0, -z[0]]);
  const y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]];
  return [...x, ...y, ...z, ...at];
}

function audit(high, patched, setup) {
  const calls = Object.fromEntries(METHODS.map(name => [name, 0]));
  const totals = Object.fromEntries(TOTALS.map(name => [name, 0]));
  const depth = high && !patched ? 3 : 0;
  calls.checkFramebufferStatus = totals.checks = totals.complete = 6 + depth;
  calls.blitFramebuffer = totals.blits = 12 + depth;
  totals.color_blits = 9;
  totals.depth_blits = 6 + depth;
  totals.stencil_blits = 3 + depth;
  if (setup) {
    // Full-root setup is deliberately not forced to the microfixture delta.
    calls.createTexture = calls.texImage2D = totals.texture_allocations = patched ? 8 : 4;
    totals.color_texture_allocations = totals.texture_allocations;
  }
  return {contexts: 1, canvas_id: 'canvas', calls, totals,
    incomplete_statuses: [], incomplete_status_overflow: 0,
    multisample_samples: {'0': 0, '1': 0, '2': 0, '4': 0, '8': 0, other: 0},
    scope: 'Synthetic all-context data; not uniquely backbuffer3d', adds_driver_queries: false, consumes_get_error: false};
}

function syntheticReview(patched = false) {
  const captures = STAGES.map(stage => {
    const transform = cameraTransform(stage.name), high = stage.quality === 'High';
    const scale = high ? 1 : Math.sqrt((stage.quality === 'Balanced' ? 1920 * 1080 : 1280 * 720) / (stage.physical[0] * stage.physical[1]));
    const heldLocal = [0.54, 0, 0, 0, 0.54, 0, 0, 0, 0.54, 0.24, -0.25, -0.55];
    const heldWorld = Array(12).fill(0);
    for (let column = 0; column < 4; column++) for (let row = 0; row < 3; row++) {
      let value = column === 3 ? transform[9 + row] : 0;
      for (let axis = 0; axis < 3; axis++) value += transform[axis * 3 + row] * heldLocal[column * 3 + axis];
      heldWorld[column * 3 + row] = value;
    }
    return {name: stage.name, fixture: 'full-map root-window render correctness; not gameplay or FPS', build: 'synthetic-build',
      renderer: 'gl_compatibility', setup_frames: 3, steady_frames: 3,
      setup_visible_draw_calls: [500, 500, 500], steady_visible_draw_calls: [500, 500, 500],
      setup_audit: audit(high, patched, true), steady_audit: audit(high, patched, false),
      before_errors: structuredClone(errorDrain), setup_errors: structuredClone(errorDrain),
      steady_errors: structuredClone(errorDrain), final_errors: structuredClone(errorDrain),
      render: {quality: stage.quality, ssao: high, viewport: [...stage.physical], viewport_pixels: [...stage.pixels],
        scale_3d: scale, render_3d: stage.pixels.map(size => Math.trunc(size * scale)), logical_size: [1280, 720], draw_calls: 500, primitives: 90000},
      window: {class: 'Window', size: [...stage.physical], canvas_size: [...stage.physical], root_3d_enabled: true, use_xr: false, subviewports: 0},
      camera: {mode: 'player', position_xyz: transform.slice(9), basis: [transform.slice(0, 3), transform.slice(3, 6), transform.slice(6, 9)],
        fov_degrees: 80, near: REPORT.camera.near, far: 200, keep_aspect: 1, transform, top_level: true, current: true},
      environment: {background_mode: 2, sky_class: 'Sky', sky_material_class: 'ProceduralSkyMaterial', tonemap_mode: 2,
        tonemap_exposure: 0.95, fog_enabled: true, fog_density: 0.0016, fog_sky_affect: 0.15, ssao_enabled: high,
        ssao_radius: 1.3, ssao_intensity: 1, ambient_energy: 0.4, ambient_color: [0.7, 0.8, 0.9, 1], fog_light_color: [0.8, 0.7, 0.6, 1],
        sky_colors: {top: [0.3, 0.4, 0.7, 1], horizon: [0.5, 0.4, 0.3, 1],
          ground_bottom: [0.3, 0.4, 0.5, 1], ground_horizon: [0.6, 0.5, 0.4, 1]}},
      shadows: [{enabled: true, mode: high ? 2 : 1, distance: high ? 110 : stage.quality === 'Balanced' ? 70 : 50,
        blend_splits: high, bias: 0.035, transform: [...identity, 0, 0, 0]}],
      msaa_3d: stage.quality === 'Performance' ? 0 : 1,
      hud: {visible: true, menu_visible: false, diagnostics: false, manual_redraws: 6, size: [1280, 720]},
      viewmodel: {visible: true, camera_child: true, slot: 0, gun_name: 'synthetic_m4', held_local: heldLocal, held_world: heldWorld,
        gun_local: [...identity, 0, 0, 0], bounds: [-0.1, -0.1, -0.6, 0.2, 0.2, 0.8], clear: true, withdrawal: 0},
      state: {paused: false, game_elapsed: 0, phase: 'LIVE', phase_left: 100, silent_test: true, muted: true,
        process_disabled: true, physics_disabled: true, input_disabled: true, mouse_captured: false,
        operators: structuredClone(REPORT.operators), poses_unchanged: true, ai_unchanged: true,
        sleeping_skeleton_updates: 0, skeleton_updates: 0, total_bots: 9,
        poses_sha256: 'd'.repeat(64), ai_sha256: 'e'.repeat(64), player_position: transform.slice(9).map((value, axis) => value - (axis === 1 ? 1.62 : 0)),
        player_yaw: Math.atan2(transform[6], transform[8]), pitch: Math.asin(-transform[7])},
      world: {batching: {source_boxes: 100, batches: 20}, static_bodies: 100, mesh_instances: 120, multimesh_instances: 16}, checks: 20, failures: 0};
  });
  return {engine_map_review: true, staged: true, expected_patch: patched,
    engine: {template: patched ? 'synthetic-patched' : 'synthetic-original', js_sha256: 'a'.repeat(64), wasm_sha256: (patched ? 'b' : 'c').repeat(64)},
    summary: {stages: 8, checks: 164, failures: 0, failure_labels: [], setup_frames: 3, steady_frames: 3,
      measurement: 'full-map root-window render correctness; not gameplay or FPS', reported_source_build: REPORT.build,
      reported_camera: structuredClone(REPORT.camera), reported_operators: structuredClone(REPORT.operators)}, captures};
}

function rejects(change, message) {
  check(() => {
    const value = syntheticReview();
    change(value, value.captures[0]);
    assert.throws(() => validateReview(value, imageFor), message);
  });
}

check(() => {
  const a = syntheticReview(), b = syntheticReview(true), before = JSON.stringify([a, b]);
  const result = compareReviews(a, b, imageFor, imageFor);
  assert.equal(result.pairs.length, 8);
  assert(result.pairs.every(pair => pair.changed_pixels === 0));
  assert.deepEqual(result.pairs.map(pair => pair.steady_depth_blits_delta), [-3, 0, 0, -3, -3, -3, -3, -3]);
  assert.deepEqual(result.pairs[0].setup_allocations.map(value => value.textures), [4, 8], 'Setup allocations recorded without an invented exact delta');
  assert.equal(JSON.stringify([a, b]), before, 'Input evidence not mutated');
});
rejects(value => value.engine_map_review = false, /strictly equal/);
rejects(value => value.staged = false, /staged/);
rejects(value => value.engine.wasm_sha256 = 'unverified', /exported/);
rejects(value => value.summary.stages = 7, /strictly equal/);
rejects(value => value.summary.failures = 1, /strictly equal/);
rejects(value => value.summary.reported_camera.basis[0][0] = -0.589175, /reported input/);
rejects(value => value.captures.reverse(), /ordered/);
rejects(value => value.captures.push(value.captures[0]), /ordered/);
rejects(value => value.captures.pop(), /ordered/);
rejects((value, capture) => capture.name = '../other', /ordered/);
rejects((value, capture) => capture.renderer = 'dummy', /strictly equal/);
rejects((value, capture) => capture.window.class = 'SubViewport', /root Window/);
rejects((value, capture) => capture.window.root_3d_enabled = false, /strictly equal/);
rejects((value, capture) => capture.window.canvas_size = [2208, 1242], /deep-equal/);
rejects((value, capture) => capture.window.subviewports = 1, /strictly equal/);
rejects((value, capture) => capture.render.viewport_pixels = [2560, 1242], /drawable/);
rejects((value, capture) => capture.render.scale_3d = 0.5, /scale/);
rejects((value, capture) => capture.render.render_3d = [1600, 900], /3D target/);
rejects((value, capture) => capture.render.primitives = 0, /primitives/);
rejects((value, capture) => capture.camera.mode = 'other', /player camera/);
rejects((value, capture) => capture.camera.top_level = false, /reported basis/);
rejects((value, capture) => capture.camera.transform[0] = NaN, /finite vector/);
rejects((value, capture) => capture.camera.transform[0] += 0.001, /reported camera/);
rejects((value, capture) => capture.camera.fov_degrees = 75, /Reported lens/);
rejects((value, capture) => capture.camera.basis[2][2] *= -1, /basis/);
rejects((value, capture) => capture.environment.background_mode = 1, /sky/);
rejects((value, capture) => capture.environment.tonemap_mode = 0, /filmic/);
rejects((value, capture) => capture.environment.ssao_enabled = false, /strictly equal/);
rejects((value, capture) => capture.environment.fog_enabled = false, /strictly equal/);
rejects((value, capture) => capture.environment.sky_colors.top[0] = Infinity, /Sky color/);
rejects((value, capture) => capture.shadows[0].enabled = false, /Shadows/);
rejects((value, capture) => capture.shadows[0].mode = 1, /splits/);
rejects((value, capture) => capture.hud.visible = false, /HUD/);
rejects((value, capture) => capture.hud.manual_redraws = 5, /redraw/);
rejects((value, capture) => capture.viewmodel.visible = false, /first-person/);
rejects((value, capture) => capture.viewmodel.camera_child = false, /strictly equal/);
rejects((value, capture) => capture.viewmodel.held_world[9] += 0.01, /camera-relative/);
rejects((value, capture) => capture.viewmodel.bounds[3] = 0, /hull/);
rejects((value, capture) => capture.state.input_disabled = false, /input_disabled/);
rejects((value, capture) => capture.state.game_elapsed = 1, /strictly equal/);
rejects((value, capture) => capture.state.operators.sleeping = 6, /counts/);
rejects((value, capture) => capture.state.skeleton_updates = 1, /palette/);
rejects((value, capture) => capture.state.poses_sha256 = 'unknown', /frozen/);
rejects((value, capture) => capture.state.player_position[1] += 1, /aligned/);
rejects((value, capture) => capture.world.static_bodies = 0, /static_bodies/);
rejects((value, capture) => capture.setup_visible_draw_calls.pop(), /Three actual/);
rejects((value, capture) => capture.steady_visible_draw_calls[0] = 0, /submissions/);
rejects((value, capture) => capture.steady_visible_draw_calls[0]++, /unchanged/);
for (const phase of ['before', 'setup', 'steady', 'final']) {
  rejects((value, capture) => capture[`${phase}_errors`].drained = false, /drain/);
  rejects((value, capture) => capture[`${phase}_errors`].errors.push(0x0502), /GL errors/);
  rejects((value, capture) => capture[`${phase}_errors`].reads = 0, /NO_ERROR/);
}
rejects((value, capture) => capture.setup_audit.totals.incomplete = 1, /incomplete/);
rejects((value, capture) => capture.steady_audit.calls.texImage2D = 1, /strictly equal/);
rejects((value, capture) => delete capture.steady_audit.calls.blitFramebuffer, /exact fields/);
check(() => assert.throws(() => validateReview(syntheticReview(), () => ({width: 1, height: 1, data: Buffer.alloc(4)})), /PNG dimensions/));
check(() => assert.throws(() => validateReview(syntheticReview(), capture => {
  const image = imageFor(capture);
  return {...image, data: Buffer.alloc(image.data.length, 255)};
}), /Nonblank/));
check(() => assert.throws(() => validateReview(syntheticReview()), /PNG readback/));
check(() => assert.throws(() => validateReview(syntheticReview(), capture => {
  const image = imageFor(capture);
  if (capture.name !== 'reported-high-restored') return image;
  const data = Buffer.from(image.data);
  data[0]++;
  return {...image, data};
}), /restores exact/));
check(() => {
  const a = syntheticReview(), b = syntheticReview(true);
  b.captures[0].steady_audit.calls.checkFramebufferStatus++;
  b.captures[0].steady_audit.totals.checks++;
  b.captures[0].steady_audit.totals.complete++;
  assert.throws(() => compareReviews(a, b, imageFor, imageFor), /expected steady calls.checkFramebufferStatus/);
});
check(() => assert.throws(() => compareReviews(syntheticReview(), syntheticReview(true), imageFor, capture => {
  const image = imageFor(capture);
  if (capture.name !== 'a-site-high') return image;
  const data = Buffer.from(image.data);
  data[0]++;
  return {...image, data};
}), /PNG mismatch.*changed_pixels":1/));
check(() => {
  const source = fs.readFileSync(path.join(__dirname, 'engine_map_review.gd'), 'utf8');
  for (const name of NAMES) assert(source.includes(`"${name}"`));
  assert.match(source, /SETUP_FRAMES := 3/);
  assert.match(source, /STEADY_FRAMES := 3/);
  assert.match(source, /camera = game\.player\.camera/);
  assert.match(source, /window\.engineMapReviewSummary=/);
  assert.match(source, /gl\.getError\(\)/);
});
check(() => {
  const image = {width: 1, height: 1, data: Buffer.from([1, 2, 3, 255])};
  assert.deepEqual(exactImage(image, image), {changed_pixels: 0, max_channel_delta: 0, absolute_channel_delta: 0});
  assert.equal(exactImage(image, {...image, data: Buffer.from([2, 2, 3, 255])}).changed_pixels, 1);
});
console.log(`ENGINE_MAP_REVIEW_CHECK: ${checks}/${checks} passed (synthetic contracts, not rendered evidence)`);
