'use strict';

// Synthetic evidence-contract regressions, not real rendering or FPS evidence.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {NAMES, STAGES, METHODS, TOTALS, validateReview, compareReviews,
  imageDifference, imageVariation, expectedDelta} = require('./depth-copy-review');

let checks = 0;
function check(callback) { callback(); checks++; }
const identity = [1, 0, 0, 0, 1, 0, 0, 0, 1];
const errorDrain = {errors: [], drained: true, context_lost: false, reads: 1};
const imageCache = new Map();

function imageFor(capture) {
  let shade = capture.ssao ? 1 : 0;
  if (capture.alpha_depth_writer) shade = 2;
  if (capture.name === 'control-depth-shift') shade = 3;
  if (capture.name === 'control-screen-tint') shade = 4;
  const [width, height] = capture.resolution;
  const key = `${width}:${height}:${shade}`;
  if (!imageCache.has(key)) {
    const data = Buffer.alloc(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const at = (y * width + x) * 4;
      data[at] = 40 + x % 24;
      data[at + 1] = 80 + y % 32;
      data[at + 2] = 100 + shade;
      data[at + 3] = 255;
    }
    imageCache.set(key, {width, height, data});
  }
  return imageCache.get(key);
}

function syntheticReview(patched = false) {
  let inventory = {fbo: false, color: false, depth: false};
  function audit(stage, phase, fresh) {
    const frames = phase === 'setup' ? 3 : 12;
    const needsDepth = ['depth', 'both'].includes(stage.reader) || (stage.ssao && !patched);
    const needsColor = ['screen', 'both'].includes(stage.reader);
    const reconfigure = phase === 'setup' && (fresh || stage.name.includes('resized'));
    if (reconfigure) inventory = {fbo: false, color: false, depth: false};
    const calls = Object.fromEntries(METHODS.map(name => [name, 0]));
    const totals = Object.fromEntries(TOTALS.map(name => [name, 0]));
    const samples = Object.fromEntries(['0', '1', '2', '4', '8', 'other'].map(name => [name, 0]));
    calls.checkFramebufferStatus = frames * Number(needsDepth || needsColor) + (reconfigure ? 2 : 0);
    calls.blitFramebuffer = frames * (2 + Number(needsDepth) + Number(needsColor) + Number(stage.msaa > 0));
    totals.color_blits = frames * (2 + Number(needsColor) + Number(stage.msaa > 0));
    totals.depth_blits = frames * (Number(stage.ssao) + Number(needsDepth) + Number(stage.msaa > 0));
    totals.stencil_blits = frames * (Number(stage.ssao) + Number(needsDepth));
    if (reconfigure) {
      calls.createFramebuffer = 2;
      totals.color_texture_allocations = 2;
      totals.depth_texture_allocations = 1 + Number(stage.ssao);
      if (stage.msaa) {
        calls.renderbufferStorageMultisample = 2;
        calls.framebufferRenderbuffer = 2;
        samples[String(stage.msaa)] = 2;
      }
    }
    if (needsDepth || needsColor) {
      if (!inventory.fbo) { calls.createFramebuffer++; inventory.fbo = true; }
      if (needsColor && !inventory.color) { totals.color_texture_allocations++; inventory.color = true; }
      if (needsDepth && !inventory.depth) { totals.depth_texture_allocations++; inventory.depth = true; }
    }
    totals.texture_allocations = totals.color_texture_allocations + totals.depth_texture_allocations;
    calls.createTexture = calls.texImage2D = calls.framebufferTexture2D = totals.texture_allocations;
    totals.renderbuffer_allocations = calls.renderbufferStorageMultisample;
    totals.attachments = calls.framebufferTexture2D + calls.framebufferRenderbuffer;
    totals.color_attachments = totals.color_texture_allocations + Number(calls.framebufferRenderbuffer > 0);
    totals.depth_attachments = totals.stencil_attachments = totals.depth_texture_allocations + Number(calls.framebufferRenderbuffer > 0);
    totals.checks = totals.complete = calls.checkFramebufferStatus;
    totals.blits = calls.blitFramebuffer;
    return {contexts: 1, canvas_id: 'canvas', adds_driver_queries: false, consumes_get_error: false,
      scope: 'Synthetic native-call evidence; not uniquely backbuffer3d', calls, totals,
      incomplete_statuses: [], incomplete_status_overflow: 0, multisample_samples: samples};
  }
  const captures = STAGES.map(stage => {
    const fresh = stage.kind === 'cold' || ['live-none-start', 'control-both-reference'].includes(stage.name);
    const shifted = ['control-depth-shift', 'control-screen-tint'].includes(stage.name);
    return {...structuredClone(stage), fresh_viewport: fresh,
      depth_consumer: ['depth', 'both'].includes(stage.reader), screen_consumer: ['screen', 'both'].includes(stage.reader),
      depth_reader_count: Number(['depth', 'both'].includes(stage.reader)),
      screen_reader_count: Number(['screen', 'both'].includes(stage.reader)),
      alpha_depth_writer_count: Number(stage.alpha_depth_writer), alpha_writer_uses_sampler: false,
      msaa_3d: [0, 2, 4].indexOf(stage.msaa), view_count: 1, own_world_3d: true, use_xr: false,
      root_3d_disabled: true, viewport_update_mode: 4, scale_3d: 1, renderer: 'gl_compatibility',
      fixture: 'Synthetic fixture; not FPS', counter_scope: 'All context calls; not uniquely backbuffer3d',
      error_probe: 'Explicit getError reads', setup_frames: 3, steady_frames: 12,
      setup_visible_draw_calls: [8, 8, 8], steady_visible_draw_calls: Array(12).fill(8),
      setup_audit: audit(stage, 'setup', fresh), steady_audit: audit(stage, 'steady', fresh),
      before_errors: structuredClone(errorDrain), setup_errors: structuredClone(errorDrain),
      steady_errors: structuredClone(errorDrain), final_errors: structuredClone(errorDrain),
      checks: 22, failures: 0, panel_rois: {depth: [20, 20, 64, 64], screen: [400, 20, 64, 64]},
      camera: {transform: [...identity, 0, 1.5, 6], fov: 60, near: 0.05, far: 30},
      environment: {ssao_radius: 1.3, ssao_intensity: 1, ambient_energy: 0.65, tonemap_mode: 0, shadows: false},
      materials: {reader_alpha: 1, reader_depth_write: false, alpha_writer_alpha: 0, alpha_writer_depth_write: true,
        depth_source_transform: [...identity, -1.25, 0.85, shifted ? -2.8 : -0.8],
        screen_source_color: (stage.name === 'control-screen-tint' ? [208, 68, 184, 255] : [79, 166, 147, 255]).map(value => value / 255)},
    };
  });
  return {depth_copy_review: true, expected_patch: patched,
    engine: {template: patched ? 'synthetic patched' : 'synthetic original', js_sha256: 'a'.repeat(64), wasm_sha256: (patched ? 'c' : 'b').repeat(64)},
    summary: {stages: 37, checks: 2 + captures.length * 22, failures: 0, failure_labels: [], cold_cases: 24,
      live_cases: 10, control_cases: 3, setup_frames: 3, steady_frames: 12, measurement: 'Synthetic contract; not FPS'}, captures};
}

function rejects(change, message) {
  check(() => {
    const value = syntheticReview();
    change(value, value.captures[0]);
    assert.throws(() => validateReview(value, imageFor), message);
  });
}

check(() => assert.equal(NAMES.length, 37));
check(() => assert.equal(new Set(NAMES).size, 37));
check(() => assert.equal(validateReview(syntheticReview(), imageFor).positive_controls.length, 6));
check(() => assert.equal(validateReview(syntheticReview(true), imageFor).stages, 37));
check(() => {
  const baseline = syntheticReview(), patched = syntheticReview(true);
  const before = JSON.stringify([baseline, patched]);
  const report = compareReviews(baseline, patched, imageFor, imageFor);
  assert.equal(report.pairs.length, 37);
  assert(report.pairs.every(pair => pair.changed_pixels === 0));
  assert.match(report.label, /not .*FPS proof/);
  assert.equal(JSON.stringify([baseline, patched]), before, 'Input evidence unchanged');
});

rejects(value => value.depth_copy_review = false, /isolated/);
rejects(value => delete value.expected_patch, /expectation/);
rejects(value => value.engine.wasm_sha256 = 'unknown', /SHA|sha256/);
rejects(value => value.summary.failures++, /assertions/);
rejects(value => value.summary.cold_cases--, /cold_cases/);
rejects(value => value.summary.failure_labels.push('bad'), /deep-equal/);
rejects(value => value.summary.stages--, /summary/);
rejects(value => value.captures.pop(), /stage names/);
rejects(value => value.captures.push(value.captures[0]), /stage names/);
rejects(value => value.captures.reverse(), /stage names/);
rejects((value, capture) => capture.name = '../outside', /stage names/);
rejects((value, capture) => capture.reader = 'depth', /reader/);
rejects((value, capture) => capture.resolution = [320, 180], /resolution/);
rejects((value, capture) => capture.msaa_3d = 2, /strictly equal/);
rejects((value, capture) => capture.renderer = 'dummy', /renderer/);
rejects((value, capture) => capture.scale_3d = 0.5, /resolution reduction/);
rejects((value, capture) => capture.root_3d_disabled = false, /isolated/);
rejects((value, capture) => capture.fresh_viewport = false, /Fresh buffers/);
rejects((value, capture) => capture.setup_frames = 2, /strictly equal/);
rejects((value, capture) => capture.steady_visible_draw_calls.pop(), /complete actual frame/);
rejects((value, capture) => capture.setup_visible_draw_calls[0] = 0, /actual visible/);
rejects((value, capture) => capture.steady_visible_draw_calls[0]++, /Stable visible/);
rejects((value, capture) => capture.camera.transform[0] = NaN, /finite vector/);
rejects((value, capture) => capture.camera.fov = 75, /Camera FOV/);
rejects((value, capture) => capture.environment.ssao_intensity = 0, /SSAO intensity/);
rejects((value, capture) => capture.environment.shadows = true, /shadow-map/);
rejects((value, capture) => capture.materials.reader_alpha = 0.94, /Opaque sampler/);
rejects((value, capture) => capture.materials.alpha_writer_alpha = 0.5, /Invisible alpha/);
rejects((value, capture) => capture.alpha_writer_uses_sampler = true, /cannot force/);
rejects((value, capture) => capture.depth_reader_count = 1, /strictly equal/);
for (const phase of ['before', 'setup', 'steady', 'final']) {
  rejects((value, capture) => capture[`${phase}_errors`].errors.push(0x0502), /native GL errors/);
  rejects((value, capture) => capture[`${phase}_errors`].drained = false, /NO_ERROR/);
  rejects((value, capture) => capture[`${phase}_errors`].context_lost = true, /context loss/);
  rejects((value, capture) => capture[`${phase}_errors`].reads = 0, /actual native/);
}
rejects((value, capture) => capture.setup_audit.contexts = 0, /actual owned/);
rejects((value, capture) => capture.setup_audit.totals.exceptions = 1, /exceptions/);
rejects((value, capture) => capture.setup_audit.totals.incomplete = 1, /incomplete/);
rejects((value, capture) => capture.setup_audit.totals.depth_blits = NaN, /integer/);
rejects((value, capture) => delete capture.setup_audit.calls.texImage2D, /complete exact fields/);
rejects((value, capture) => capture.steady_audit.calls.createTexture = 1, /steady createTexture/);
rejects((value, capture) => capture.panel_rois.depth = [-1, 20, 30, 30], /rectangle/);
rejects((value, capture) => capture.panel_rois.screen = [639, 359, 5, 5], /inside PNG/);

check(() => assert.throws(() => validateReview(syntheticReview(), () => ({width: 1, height: 1, data: Buffer.alloc(4)})), /PNG dimensions/));
check(() => assert.throws(() => validateReview(syntheticReview(), capture => ({...imageFor(capture), data: Buffer.alloc(4)})), /RGBA bytes/));
check(() => assert.throws(() => validateReview(syntheticReview(), capture => {
  const image = imageFor(capture), data = Buffer.alloc(image.data.length, 255);
  return {...image, data};
}), /nonblank/));
check(() => assert.throws(() => validateReview(syntheticReview()), /PNG readback/));
check(() => assert.throws(() => validateReview(syntheticReview(), capture => imageFor({...capture, ssao: false, alpha_depth_writer: false})), /SSAO on\/off/));
check(() => assert.throws(() => validateReview(syntheticReview(), capture => imageFor({...capture,
  name: capture.name === 'control-depth-shift' ? 'control-both-reference' : capture.name})), /depth sample/));
check(() => assert.throws(() => validateReview(syntheticReview(), capture => imageFor({...capture, alpha_depth_writer: false})), /alpha writer changes/));

check(() => {
  const baseline = syntheticReview(), patched = syntheticReview(true);
  const capture = patched.captures.find(value => value.name === 'cold-none-ssao-on-msaa-0');
  capture.steady_audit.calls.blitFramebuffer++;
  capture.steady_audit.totals.blits++;
  assert.throws(() => compareReviews(baseline, patched, imageFor, imageFor), /exact calls.blitFramebuffer delta/);
});
check(() => {
  const baseline = syntheticReview(), patched = syntheticReview(true);
  patched.captures[0].setup_audit.calls.createFramebuffer++;
  assert.throws(() => compareReviews(baseline, patched, imageFor, imageFor), /createFramebuffer delta/);
});
check(() => {
  const patchedImage = capture => {
    const image = imageFor(capture);
    if (capture.name !== NAMES[0]) return image;
    const data = Buffer.from(image.data);
    data[0]++;
    return {...image, data};
  };
  assert.throws(() => compareReviews(syntheticReview(), syntheticReview(true), imageFor, patchedImage), /PNG mismatch.*changed_pixels":1/);
});

for (const reader of ['none', 'depth', 'screen', 'both']) for (const ssao of [false, true]) for (const msaa of [0, 2, 4]) {
  check(() => {
    const stage = STAGES.find(value => value.kind === 'cold' && value.reader === reader && value.ssao === ssao && value.msaa === msaa);
    const delta = expectedDelta(stage, 'steady');
    const omitted = ssao && (reader === 'none' || reader === 'screen');
    assert.equal(delta.totals.depth_blits, omitted ? -12 : 0);
    assert.equal(delta.totals.checks, omitted && reader === 'none' ? -12 : 0);
    assert.equal(expectedDelta(stage, 'setup').calls.createTexture, omitted ? -1 : 0);
  });
}
check(() => assert.equal(expectedDelta(STAGES.find(stage => stage.name === 'live-depth-added'), 'setup').calls.createTexture, 1));
check(() => assert.equal(expectedDelta(STAGES.find(stage => stage.name === 'live-screen-only'), 'setup').calls.createTexture, 0));

check(() => {
  const a = {width: 2, height: 1, data: Buffer.from([0, 1, 2, 255, 3, 4, 5, 255])};
  const b = {...a, data: Buffer.from(a.data)};
  b.data[1] = 7;
  assert.deepEqual(imageDifference(a, b), {changed_pixels: 1, max_channel_delta: 6, absolute_channel_delta: 6});
  assert.equal(imageVariation(a).colors_at_least, 2);
  const {PNG} = require('playwright-core/lib/utilsBundle');
  assert.deepEqual(PNG.sync.read(PNG.sync.write(a)).data, a.data, 'Actual pinned PNG decoder works offline');
});
check(() => {
  const source = fs.readFileSync(path.join(__dirname, 'depth_copy_review.gd'), 'utf8');
  assert.match(source, /SETUP_FRAMES := 3/);
  assert.match(source, /STEADY_FRAMES := 12/);
  assert.match(source, /window\.depthCopyReviewSummary=/);
  assert.match(source, /gl\.getError\(\)/);
  for (const name of NAMES.filter(name => !name.startsWith('cold-'))) assert(source.includes(`"${name}"`), `Actual fixture stage ${name}`);
});

console.log(`DEPTH_COPY_REVIEW_CHECK: ${checks}/${checks} passed (synthetic contract and offline PNG tests; no rendered proof)`);
