'use strict';

// Offline renderer-evidence validation only. Never launches a browser, compiles
// an engine, edits artifacts, or treats source checks/call counts as FPS proof.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const READERS = ['none', 'depth', 'screen', 'both'];
const MSAA = [0, 2, 4];
const STAGES = READERS.flatMap(reader => [false, true].flatMap(ssao => MSAA.map(msaa => ({
  name: `cold-${reader}-ssao-${ssao ? 'on' : 'off'}-msaa-${msaa}`, kind: 'cold', reader, ssao, msaa,
  resolution: [640, 360], alpha_depth_writer: false,
}))));
for (const [name, reader, resized, alpha] of [
  ['none-start', 'none'], ['depth-added', 'depth'], ['both-added', 'both'],
  ['screen-only', 'screen'], ['none-restored', 'none'], ['alpha-writer', 'none', false, true],
  ['alpha-removed', 'none'], ['both-restored', 'both'], ['both-resized', 'both', true],
  ['none-resized-back', 'none'],
]) STAGES.push({name: `live-${name}`, kind: 'live', reader, ssao: true, msaa: 4,
  resolution: resized ? [736, 414] : [640, 360], alpha_depth_writer: !!alpha});
for (const name of ['both-reference', 'depth-shift', 'screen-tint']) STAGES.push({
  name: `control-${name}`, kind: 'control', reader: 'both', ssao: false, msaa: 0,
  resolution: [640, 360], alpha_depth_writer: false,
});
const NAMES = STAGES.map(stage => stage.name);
const METHODS = ['checkFramebufferStatus', 'createFramebuffer', 'deleteFramebuffer',
  'createTexture', 'deleteTexture', 'texImage2D', 'texImage3D', 'texStorage2D', 'texStorage3D',
  'copyTexImage2D', 'renderbufferStorage', 'renderbufferStorageMultisample',
  'framebufferTexture2D', 'framebufferTextureLayer', 'framebufferRenderbuffer', 'blitFramebuffer'];
const TOTALS = ['checks', 'complete', 'incomplete', 'exceptions', 'texture_allocations',
  'color_texture_allocations', 'depth_texture_allocations', 'unknown_texture_allocations',
  'renderbuffer_allocations', 'attachments', 'color_attachments', 'depth_attachments', 'stencil_attachments',
  'blits', 'color_blits', 'depth_blits', 'stencil_blits'];

function integer(value, minimum, label) {
  assert(Number.isSafeInteger(value) && value >= minimum, `${label}: integer >= ${minimum}`);
}

function imageShape(image, dimensions, label) {
  assert(image && typeof image === 'object', `${label}: decoded PNG`);
  dimensions.forEach(value => integer(value, 1, `${label} dimension`));
  assert.deepEqual([image.width, image.height], dimensions, `${label}: actual PNG dimensions`);
  assert(image.data instanceof Uint8Array, `${label}: complete RGBA bytes`);
  assert.equal(image.data.length, dimensions[0] * dimensions[1] * 4, `${label}: complete RGBA bytes`);
}

function imageDifference(a, b) {
  imageShape(b, [a.width, a.height], 'Compared image');
  imageShape(a, [b.width, b.height], 'Reference image');
  let changedPixels = 0, maxChannelDelta = 0, absoluteChannelDelta = 0;
  for (let at = 0; at < a.data.length; at += 4) {
    let changed = false;
    for (let channel = 0; channel < 4; channel++) {
      const delta = Math.abs(a.data[at + channel] - b.data[at + channel]);
      changed ||= delta !== 0;
      maxChannelDelta = Math.max(maxChannelDelta, delta);
      absoluteChannelDelta += delta;
    }
    changedPixels += Number(changed);
  }
  return {changed_pixels: changedPixels, max_channel_delta: maxChannelDelta, absolute_channel_delta: absoluteChannelDelta};
}

function regionDifference(a, b, rectangle) {
  imageShape(b, [a.width, a.height], 'Compared ROI image');
  imageVariation(a, rectangle); // Validate the rectangle and actual RGBA data.
  const [x, y, width, height] = rectangle;
  let changed = 0;
  for (let row = y; row < y + height; row++) for (let column = x; column < x + width; column++) {
    const at = (row * a.width + column) * 4;
    if ([0, 1, 2].some(channel => a.data[at + channel] !== b.data[at + channel])) changed++;
  }
  return changed;
}

function imageVariation(image, rectangle = [0, 0, image.width, image.height]) {
  imageShape(image, [image.width, image.height], 'Positive-control image');
  assert(Array.isArray(rectangle) && rectangle.length === 4, 'Image control rectangle');
  rectangle.forEach(value => integer(value, 0, 'Image control rectangle'));
  const [x, y, width, height] = rectangle;
  assert(width > 0 && height > 0 && x + width <= image.width && y + height <= image.height, 'Image control rectangle inside PNG');
  const minimum = [255, 255, 255], maximum = [0, 0, 0], colors = new Set();
  for (let row = y; row < y + height; row++) for (let column = x; column < x + width; column++) {
    const at = (row * image.width + column) * 4;
    assert.equal(image.data[at + 3], 255, 'Opaque fixture screenshot');
    for (let channel = 0; channel < 3; channel++) {
      minimum[channel] = Math.min(minimum[channel], image.data[at + channel]);
      maximum[channel] = Math.max(maximum[channel], image.data[at + channel]);
    }
    if (colors.size < 16) colors.add((image.data[at] << 16) | (image.data[at + 1] << 8) | image.data[at + 2]);
  }
  return {colors_at_least: colors.size, channel_span: Math.max(...maximum.map((value, channel) => value - minimum[channel]))};
}

function keys(object, expected, label) {
  assert(object && typeof object === 'object' && !Array.isArray(object), `${label}: object`);
  assert.deepEqual(Object.keys(object).sort(), [...expected].sort(), `${label}: complete exact fields`);
}

function validateAudit(audit, label) {
  assert.equal(audit?.contexts, 1, `${label}: one actual owned WebGL2 context`);
  assert.equal(audit.canvas_id, 'canvas');
  assert.equal(audit.adds_driver_queries, false, 'Passive counters add no driver queries');
  assert.equal(audit.consumes_get_error, false, 'Error drains are separate from passive counters');
  assert.match(audit.scope, /not uniquely backbuffer3d/);
  keys(audit.calls, METHODS, `${label} native calls`);
  keys(audit.totals, TOTALS, `${label} totals`);
  for (const group of [audit.calls, audit.totals]) for (const [key, value] of Object.entries(group)) integer(value, 0, `${label} ${key}`);
  for (const key of ['exceptions', 'incomplete', 'unknown_texture_allocations']) assert.equal(audit.totals[key], 0, `${label}: no ${key}`);
  assert.deepEqual(audit.incomplete_statuses, []);
  assert.equal(audit.incomplete_status_overflow, 0);
  assert.equal(audit.totals.checks, audit.calls.checkFramebufferStatus);
  assert.equal(audit.totals.complete, audit.totals.checks);
  assert.equal(audit.totals.blits, audit.calls.blitFramebuffer);
  assert.equal(audit.totals.texture_allocations,
    audit.totals.color_texture_allocations + audit.totals.depth_texture_allocations);
  assert.equal(audit.totals.texture_allocations,
    ['texImage2D', 'texImage3D', 'texStorage2D', 'texStorage3D', 'copyTexImage2D'].reduce((sum, key) => sum + audit.calls[key], 0));
  assert.equal(audit.totals.renderbuffer_allocations, audit.calls.renderbufferStorage + audit.calls.renderbufferStorageMultisample);
  assert.equal(audit.totals.attachments,
    ['framebufferTexture2D', 'framebufferTextureLayer', 'framebufferRenderbuffer'].reduce((sum, key) => sum + audit.calls[key], 0));
  for (const key of ['color_blits', 'depth_blits', 'stencil_blits']) assert(audit.totals[key] <= audit.totals.blits);
  keys(audit.multisample_samples, ['0', '1', '2', '4', '8', 'other'], `${label} MSAA histogram`);
  for (const value of Object.values(audit.multisample_samples)) integer(value, 0, `${label} sample count`);
  assert.equal(Object.values(audit.multisample_samples).reduce((a, b) => a + b, 0), audit.calls.renderbufferStorageMultisample);
}

function validateErrors(value, label) {
  assert(value && typeof value === 'object', `${label}: actual native error drain`);
  assert.deepEqual(value.errors, [], `${label}: no native GL errors`);
  assert.equal(value.drained, true, `${label}: error drain reached NO_ERROR`);
  assert.equal(value.context_lost, false, `${label}: no context loss`);
  assert.equal(value.reads, 1, `${label}: one actual native NO_ERROR read`);
}

function vector(value, length, label) {
  assert(Array.isArray(value) && value.length === length && [...value].every(Number.isFinite), `${label}: finite vector`);
}

function near(value, expected, label) {
  assert(Number.isFinite(value) && Math.abs(value - expected) <= 1e-6, `${label}: expected ${expected}`);
}

function validateSettings(capture, stage) {
  const fresh = stage.kind === 'cold' || ['live-none-start', 'control-both-reference'].includes(stage.name);
  assert.equal(capture.fresh_viewport, fresh, 'Fresh buffers vs retained lifecycle state');
  assert.equal(capture.depth_reader_count, Number(capture.depth_consumer));
  assert.equal(capture.screen_reader_count, Number(capture.screen_consumer));
  assert.equal(capture.alpha_depth_writer_count, Number(stage.alpha_depth_writer));
  assert.equal(capture.alpha_writer_uses_sampler, false, 'Alpha writer cannot force a material depth copy');
  assert.equal(capture.own_world_3d, true);
  assert.equal(capture.use_xr, false);
  assert.equal(capture.root_3d_disabled, true, 'Only the isolated 3D view renders');
  assert.equal(capture.viewport_update_mode, 4, 'Actual UPDATE_ALWAYS viewport');
  assert.equal(capture.scale_3d, 1, 'No 3D resolution reduction');
  assert.match(capture.fixture, /not FPS/);
  assert.match(capture.error_probe, /getError/);
  assert.match(capture.counter_scope, /not uniquely backbuffer3d/);
  for (const phase of ['setup', 'steady']) {
    const draws = capture[`${phase}_visible_draw_calls`];
    assert(Array.isArray(draws) && draws.length === capture[`${phase}_frames`], `${phase}: complete actual frame samples`);
    for (const count of draws) integer(count, 1, `${phase}: actual visible draw calls`);
    if (phase === 'steady') assert(draws.every(count => count === draws[0]), 'Stable visible scene throughout steady samples');
  }
  const camera = capture.camera;
  assert(camera && typeof camera === 'object', 'Actual camera state');
  vector(camera.transform, 12, 'Camera transform');
  [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.5, 6].forEach((value, index) => near(camera.transform[index], value, 'Camera transform'));
  near(camera.fov, 60, 'Camera FOV');
  near(camera.near, 0.05, 'Camera near');
  near(camera.far, 30, 'Camera far');
  const environment = capture.environment;
  assert(environment && typeof environment === 'object', 'Actual environment state');
  near(environment.ssao_radius, 1.3, 'SSAO radius');
  assert(Number.isFinite(environment.ssao_intensity) && environment.ssao_intensity > 0, 'Nonzero actual SSAO intensity');
  near(environment.ambient_energy, 0.65, 'Ambient light');
  assert.equal(environment.tonemap_mode, 0);
  assert.equal(environment.shadows, false, 'No unrelated shadow-map audit work');
  const materials = capture.materials;
  assert(materials && typeof materials === 'object', 'Actual material state');
  assert.equal(materials.reader_alpha, 1, 'Opaque sampler panels exclude underlying color leakage');
  assert.equal(materials.reader_depth_write, false);
  assert.equal(materials.alpha_writer_alpha, 0, 'Invisible alpha writer excludes ordinary color differences');
  assert.equal(materials.alpha_writer_depth_write, true);
  vector(materials.depth_source_transform, 12, 'Depth-source transform');
  const shifted = ['control-depth-shift', 'control-screen-tint'].includes(stage.name);
  [1, 0, 0, 0, 1, 0, 0, 0, 1, -1.25, 0.85, shifted ? -2.8 : -0.8]
    .forEach((value, index) => near(materials.depth_source_transform[index], value, 'Depth-source transform'));
  vector(materials.screen_source_color, 4, 'Screen-source color');
  const color = stage.name === 'control-screen-tint' ? [208, 68, 184, 255] : [79, 166, 147, 255];
  color.forEach((value, index) => near(materials.screen_source_color[index], value / 255, 'Screen-source color'));
}

function decodeCapture(capture) {
  const png = Buffer.from(capture.png || '', 'base64');
  assert(png.length >= 24 && png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])), 'Actual PNG readback signature');
  return require('playwright-core/lib/utilsBundle').PNG.sync.read(png);
}

function validateReview(review, readImage = decodeCapture) {
  assert.equal(review?.depth_copy_review, true, 'Actual isolated depth-copy review');
  assert.equal(typeof review.expected_patch, 'boolean', 'Explicit original/patched expectation');
  for (const field of ['js_sha256', 'wasm_sha256']) assert.match(review.engine?.[field] || '', /^[a-f0-9]{64}$/, `Recorded engine ${field}`);
  assert.equal(typeof review.engine.template, 'string');
  assert.equal(review.summary?.failures, 0, 'All renderer fixture assertions passed');
  assert.equal(review.summary.stages, NAMES.length, 'Complete renderer summary');
  assert.deepEqual(review.summary.failure_labels, []);
  for (const [field, value] of Object.entries({cold_cases: 24, live_cases: 10, control_cases: 3, setup_frames: 3, steady_frames: 12})) {
    assert.equal(review.summary[field], value, `Complete summary ${field}`);
  }
  assert.match(review.summary.measurement, /not FPS/);
  integer(review.summary.checks, NAMES.length, 'Actual fixture checks');
  assert(Array.isArray(review.captures), 'All renderer captures');
  assert.deepEqual(review.captures.map(capture => capture.name), NAMES, 'Complete exact ordered stage names');
  const images = new Map();
  review.captures.forEach((capture, index) => {
    const stage = STAGES[index], label = stage.name;
    for (const [field, value] of Object.entries(stage)) assert.deepEqual(capture[field], value, `${label}: ${field}`);
    assert.equal(capture.depth_consumer, ['depth', 'both'].includes(stage.reader));
    assert.equal(capture.screen_consumer, ['screen', 'both'].includes(stage.reader));
    assert.equal(capture.msaa_3d, MSAA.indexOf(stage.msaa));
    assert.equal(capture.view_count, 1);
    assert.equal(capture.renderer, 'gl_compatibility', 'Actual compatibility renderer, never headless dummy');
    assert.equal(capture.setup_frames, 3);
    assert.equal(capture.steady_frames, 12);
    validateSettings(capture, stage);
    assert.equal(capture.failures, 0, `${label}: renderer checks passed`);
    integer(capture.checks, 1, `${label}: actual fixture checks`);
    for (const phase of ['setup', 'steady']) {
      validateAudit(capture[`${phase}_audit`], `${label} ${phase}`);
      validateErrors(capture[`${phase}_errors`], `${label} ${phase}`);
    }
    validateErrors(capture.before_errors, `${label} before setup`);
    validateErrors(capture.final_errors, `${label} post-PNG`);
    const steady = capture.steady_audit;
    for (const key of ['texture_allocations', 'renderbuffer_allocations', 'attachments']) assert.equal(steady.totals[key], 0, `${label}: steady ${key}`);
    for (const key of ['createTexture', 'deleteTexture', 'createFramebuffer', 'deleteFramebuffer']) assert.equal(steady.calls[key], 0, `${label}: steady ${key}`);
    const depth = capture.depth_consumer || (stage.ssao && !review.expected_patch);
    if (depth || capture.screen_consumer) assert(steady.totals.checks >= 12, `${label}: recurring real-reader FBO validation retained`);
    if (depth) assert(steady.totals.depth_blits >= 12, `${label}: real requested depth copies exist`);
    if ((stage.kind === 'cold' || label === 'live-none-start' || label.includes('resized')) && stage.msaa) {
      assert(capture.setup_audit.multisample_samples[String(stage.msaa)] > 0, `${label}: actual requested multisample storage`);
    }
    const image = readImage(capture);
    imageShape(image, stage.resolution, label);
    const variation = imageVariation(image);
    assert(variation.colors_at_least >= 8 && variation.channel_span >= 8, `${label}: nonblank visible scene`);
    keys(capture.panel_rois, ['depth', 'screen'], `${label} panel ROIs`);
    for (const reader of ['depth', 'screen']) {
      const region = imageVariation(image, capture.panel_rois[reader]);
      if ([reader, 'both'].includes(stage.reader)) assert(region.colors_at_least >= 2 && region.channel_span >= 2,
        `${label}: nonconstant sampled ${reader} panel`);
    }
    images.set(label, image);
  });
  assert.equal(review.summary.checks, review.captures.reduce((sum, capture) => sum + capture.checks, 2), 'Summary includes every stage and two outer fixture checks');
  const positive = [];
  function different(a, b, roi, label) {
    const changed = roi ? regionDifference(images.get(a), images.get(b), roi) : imageDifference(images.get(a), images.get(b)).changed_pixels;
    assert(changed >= 8, `${label}: positive visual control must change at least eight pixels`);
    positive.push({control: label, changed_pixels: changed});
  }
  for (const msaa of MSAA) different(`cold-none-ssao-off-msaa-${msaa}`, `cold-none-ssao-on-msaa-${msaa}`, null, `SSAO on/off MSAA ${msaa}`);
  const roi = review.captures.find(capture => capture.name === 'control-both-reference').panel_rois;
  different('control-both-reference', 'control-depth-shift', roi.depth, 'Actual opaque-panel depth sample responds to depth');
  different('control-depth-shift', 'control-screen-tint', roi.screen, 'Actual opaque-panel screen sample responds to color');
  different('live-none-restored', 'live-alpha-writer', null, 'Invisible alpha writer changes final-depth SSAO');
  assert.equal(imageDifference(images.get('live-none-restored'), images.get('live-alpha-removed')).changed_pixels, 0, 'Alpha writer removal restores exact image');
  return {stages: NAMES.length, positive_controls: positive};
}

function allocationDelta(stage) {
  if (stage.name === 'live-depth-added') return {depth: 1, fbo: 1};
  const fresh = stage.kind === 'cold' || ['live-none-start', 'live-none-resized-back'].includes(stage.name);
  const omitted = fresh && stage.ssao && !['depth', 'both'].includes(stage.reader);
  return {depth: omitted ? -1 : 0, fbo: omitted && stage.reader === 'none' ? -1 : 0};
}

function expectedDelta(stage, phase) {
  const omitted = stage.ssao && !['depth', 'both'].includes(stage.reader);
  const frames = phase === 'setup' ? 3 : 12;
  const copy = omitted ? -frames : 0;
  const checks = omitted && stage.reader === 'none' ? -frames : 0;
  const allocation = phase === 'setup' ? allocationDelta(stage) : {depth: 0, fbo: 0};
  return {
    calls: {checkFramebufferStatus: checks, blitFramebuffer: copy, createFramebuffer: allocation.fbo,
      createTexture: allocation.depth, texImage2D: allocation.depth, framebufferTexture2D: allocation.depth},
    totals: {checks, complete: checks, blits: copy, depth_blits: copy, stencil_blits: copy,
      texture_allocations: allocation.depth, depth_texture_allocations: allocation.depth,
      attachments: allocation.depth, depth_attachments: allocation.depth, stencil_attachments: allocation.depth},
  };
}

function compareReviews(baseline, patched, readBaseline = decodeCapture, readPatched = decodeCapture) {
  assert.equal(baseline?.expected_patch, false, 'Original engine first');
  assert.equal(patched?.expected_patch, true, 'Patched engine second');
  assert.notEqual(baseline.engine?.wasm_sha256, patched.engine?.wasm_sha256, 'Distinct actual original/patched Wasm binaries');
  const controls = [validateReview(baseline, readBaseline), validateReview(patched, readPatched)];
  const pairs = baseline.captures.map((a, index) => {
    const b = patched.captures[index], stage = STAGES[index];
    for (const field of ['panel_rois', 'camera', 'environment', 'materials', 'viewport_update_mode',
      'setup_visible_draw_calls', 'steady_visible_draw_calls']) {
      assert.deepEqual(b[field], a[field], `${stage.name}: matching ${field}`);
    }
    for (const phase of ['setup', 'steady']) {
      const delta = expectedDelta(stage, phase);
      for (const [group, names] of [['calls', METHODS], ['totals', TOTALS]]) for (const name of names) {
        assert.equal(b[`${phase}_audit`][group][name] - a[`${phase}_audit`][group][name], delta[group][name] || 0,
          `${stage.name} ${phase}: exact ${group}.${name} delta`);
      }
      assert.deepEqual(b[`${phase}_audit`].multisample_samples, a[`${phase}_audit`].multisample_samples, 'Unchanged MSAA allocation sample counts');
    }
    const difference = imageDifference(readBaseline(a), readPatched(b));
    assert.equal(difference.changed_pixels, 0, `${stage.name}: original/patched PNG mismatch ${JSON.stringify(difference)}`);
    return {name: stage.name, ...difference, setup_delta: expectedDelta(stage, 'setup'), steady_delta: expectedDelta(stage, 'steady')};
  });
  return {label: 'Actual fixture images and native call-count comparison; not driver-wide correctness, bandwidth, or FPS proof',
    stages: NAMES.length, controls, pairs,
    provenance_limit: 'Recorded binary hashes identify this pair; matching source/toolchain/build flags must also be verified from engine-build metadata.'};
}

if (require.main === module) {
  try {
    const args = process.argv.slice(2);
    assert(args.length === 4 && args[0] === '--baseline' && args[2] === '--patched',
      'Usage: node courtyard/tests/depth-copy-review.js --baseline DIR --patched DIR');
    const directories = [path.resolve(args[1]), path.resolve(args[3])];
    const reviews = directories.map(directory => JSON.parse(fs.readFileSync(path.join(directory, 'captures.json'), 'utf8')));
    const {PNG} = require('playwright-core/lib/utilsBundle');
    const readers = directories.map(directory => capture => PNG.sync.read(fs.readFileSync(path.join(directory, `${capture.name}.png`))));
    console.log('DEPTH_COPY_REVIEW_COMPARISON: PASS', JSON.stringify(compareReviews(...reviews, ...readers)));
  } catch (error) { console.error(`DEPTH_COPY_REVIEW_COMPARISON: FAIL: ${error.message}`); process.exitCode = 1; }
}

module.exports = {NAMES, STAGES, METHODS, TOTALS, validateReview, compareReviews, imageDifference, imageVariation, expectedDelta};
