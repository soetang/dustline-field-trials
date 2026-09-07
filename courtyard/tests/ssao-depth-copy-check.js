'use strict';

// Optional, compiler-free SOURCE CONTRACT check, not a renderer or FPS test.
// Applies one audited hunk in memory; never modifies an engine checkout.
// Usage: node courtyard/tests/ssao-depth-copy-check.js [--source PATH]
// PATH is a pristine Godot 4.7.2-stable tree or rasterizer_scene_gles3.cpp.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const relativeSource = 'drivers/gles3/rasterizer_scene_gles3.cpp';
const pinnedHash = '6d0719c9cd2caf685a9825028183bdf058081d7bc92d4b27ed2587f39b081221';
const hash = text => crypto.createHash('sha256').update(text).digest('hex');
const usage = 'Usage: node courtyard/tests/ssao-depth-copy-check.js [--source PATH]';
const before = `\t// If SSAO is enabled, we definitely need the depth buffer.
\tif (ssao_enabled) {
\t\tscene_state.used_depth_texture = true;
\t}
`;
const after = `\t// SSAO reads internal depth in post processing. Preserve the separate
\t// backbuffer copy only for material readers on non-reflection single-view Web.
\tbool ssao_needs_backbuffer = ssao_enabled;
#ifdef WEB_ENABLED
\tssao_needs_backbuffer = ssao_needs_backbuffer && (is_reflection_probe || render_data.view_count != 1);
#endif
\tif (ssao_needs_backbuffer) {
\t\tscene_state.used_depth_texture = true;
\t}
`;

function replaceOnce(source, from, to) {
  const at = source.indexOf(from);
  assert(at >= 0 && source.indexOf(from, at + 1) === -1, 'Expected one exact source match');
  return source.slice(0, at) + to + source.slice(at + from.length);
}

function applyHunk(source, patch, reverse = false) {
  const lines = patch.trimEnd().split('\n');
  assert.equal(lines[0], `--- a/${relativeSource}`);
  assert.equal(lines[1], `+++ b/${relativeSource}`);
  const header = /^@@ -(\d+),(\d+) \+(\d+),(\d+) @@$/.exec(lines[2]);
  assert(header, 'Exactly one ordinary unified-diff hunk is supported');
  const oldLines = [], newLines = [];
  for (const line of lines.slice(3)) {
    assert([' ', '+', '-'].includes(line[0]), 'Unsupported patch line or extra hunk');
    if (line[0] !== '+') oldLines.push(line.slice(1));
    if (line[0] !== '-') newLines.push(line.slice(1));
  }
  assert.equal(oldLines.length, Number(header[2]));
  assert.equal(newLines.length, Number(header[4]));
  const from = (reverse ? newLines : oldLines).join('\n') + '\n';
  const to = (reverse ? oldLines : newLines).join('\n') + '\n';
  const lineNumber = source.slice(0, source.indexOf(from)).split('\n').length;
  assert.equal(lineNumber, Number(header[reverse ? 3 : 1]), 'Hunk must match its exact line, without offsets');
  return replaceOnce(source, from, to);
}

function method(source, name) {
  // The pinned source closes complete methods at column zero. Nested braces
  // and mutually exclusive preprocessor branches are indented.
  const matches = [...source.matchAll(new RegExp(`^void RasterizerSceneGLES3::${name}\\([^]*?^\\}`, 'gm'))];
  assert.equal(matches.length, 1, `Expected one complete ${name} method`);
  return matches[0][0];
}

function section(source, start, end) {
  assert.equal(source.split(start).length, 2);
  const at = source.indexOf(start), finish = source.indexOf(end, at);
  assert(finish > at, 'Missing section end');
  return source.slice(at, finish);
}

function evaluateAssignment(block, web, ssao, reflection, views, materialDepth) {
  // Only the exact allowlisted block above is translated, not arbitrary C++.
  // This checks the actual patch's selection expression in JS; it does NOT
  // execute C++, GL, allocation, prepass, resolve, or post processing.
  assert(block === before || block === after);
  const body = block.replace(/#ifdef WEB_ENABLED\n([^]*?)#endif\n/g, (_, code) => web ? code : '')
    .replace(/\bbool\b/g, 'let');
  const scene = { used_depth_texture: materialDepth };
  new Function('ssao_enabled', 'is_reflection_probe', 'render_data', 'scene_state', body)(
    ssao, reflection, { view_count: views }, scene);
  return scene.used_depth_texture;
}

function main() {
  let requested = path.join(root, '.tools/engine-lab/godot-4.7.2-stable');
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--help') { console.log(usage); return; }
    if (args[i] === '--source') {
      assert(args[i + 1], usage); requested = path.resolve(args[++i]);
    } else if (args[i].startsWith('--source=')) {
      assert(args[i].slice(9), usage); requested = path.resolve(args[i].slice(9));
    } else throw new Error(usage);
  }
  const sourceFile = fs.existsSync(requested) && fs.statSync(requested).isDirectory()
    ? path.join(requested, relativeSource) : requested;
  if (!fs.existsSync(sourceFile)) {
    console.log(`SSAO_DEPTH_COPY_SOURCE_CHECK: SKIP (missing optional source: ${sourceFile})`);
    console.log('Supply the pristine official 4.7.2-stable source tree or CPP with --source PATH. Nothing is downloaded. Remote builds must require PASS, not SKIP.');
    return;
  }
  const original = fs.readFileSync(sourceFile, 'utf8');
  assert.equal(hash(original), pinnedHash, 'Not the audited pristine 4.7.2 CPP; do not accept patched source or upstream drift');
  const patchFile = path.join(root, 'courtyard/engine/patches/remove-ssao-depth-copy.patch');
  const patch = fs.readFileSync(patchFile, 'utf8');
  const patched = applyHunk(original, patch);
  assert.equal(patched, replaceOnce(original, before, after), 'No change outside the allowlisted SSAO flag block');
  assert.equal(applyHunk(patched, patch, true), original, 'Exact byte-for-byte patch round trip');
  assert.throws(() => applyHunk(original, patch.replace('@@ -2701,', '@@ -2702,')));
  assert.throws(() => applyHunk(patched, patch), 'Already-patched source must be rejected');

  // Pin every real depth flag assignment/read, plus full material collection and
  // post methods. The only changed thing is the SSAO-forced assignment's guard.
  const flagLines = text => text.split('\n').filter(line => line.includes('scene_state.used_depth_texture'));
  assert.deepEqual(flagLines(original).map(line => line.trim()), [
    'scene_state.used_depth_texture = false;',
    'scene_state.used_depth_texture = true;',
    'scene_state.used_depth_texture = true;',
    'if (scene_state.used_screen_texture || scene_state.used_depth_texture) {',
    'rb->check_backbuffer(scene_state.used_screen_texture, scene_state.used_depth_texture);',
    'if (scene_state.used_depth_texture) {',
  ]);
  assert.deepEqual(flagLines(patched), flagLines(original));
  for (const name of ['_geometry_instance_add_surface_with_material', '_fill_render_list', '_render_post_processing']) {
    assert.equal(method(patched, name), method(original, name), `${name} must stay byte-identical`);
  }
  for (const [start, end] of [
    ["\t// Do depth prepass if it's explicitly enabled", '\tif (scene_state.used_screen_texture || scene_state.used_depth_texture) {'],
    ['\tif (scene_state.used_screen_texture || scene_state.used_depth_texture) {', '\tRENDER_TIMESTAMP("Render 3D Transparent Pass");'],
  ]) assert.equal(section(patched, start, end), section(original, start, end));
  assert(patched.includes('if (glow_enabled || ssao_enabled || use_bcs || canvas_tonemapping) {\n\t\t\tapply_environment_effects_in_post = true;'));
  assert(patched.indexOf('rb->get_render_fbo();') < patched.indexOf(after), 'Internal-buffer setup must precede the flag change');
  const post = method(patched, '_render_post_processing');
  for (const anchor of [
    'bool msaa3d_needs_resolve = rb->get_msaa_needs_resolve();',
    'if (fbo_msaa_3d != 0 && msaa3d_needs_resolve)',
    'GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT, GL_NEAREST);',
    'GLuint depth_buffer = fbo_int != 0 ? rb->get_internal_depth() : texture_storage->render_target_get_depth(render_target);',
    'depth_buffer, ssao_enabled, ssao_quality, ssao_strength, ssao_radius,',
    'GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT, GL_NEAREST);',
  ]) assert(post.includes(anchor), `Missing audited internal-depth/post-resolve anchor: ${anchor}`);

  let cases = 0, changed = 0;
  for (const web of [false, true]) for (const reflection of [false, true]) {
    for (const views of [1, 2, 4]) for (const ssao of [false, true]) for (const materialDepth of [false, true]) {
      const oldFlag = evaluateAssignment(before, web, ssao, reflection, views, materialDepth);
      const newFlag = evaluateAssignment(after, web, ssao, reflection, views, materialDepth);
      assert.equal(oldFlag, materialDepth || ssao);
      assert.equal(newFlag, materialDepth || (ssao && (!web || reflection || views !== 1)));
      if (oldFlag !== newFlag) { changed++; assert(web && !reflection && views === 1 && ssao && !materialDepth); }
      cases++;
    }
  }
  assert.equal(cases, 48);
  assert.equal(changed, 1);
  assert.equal(fs.readFileSync(sourceFile, 'utf8'), original, 'Source changed during check');
  assert.equal(fs.readFileSync(patchFile, 'utf8'), patch, 'Patch changed during check');
  console.log(`Pristine CPP SHA256: ${pinnedHash}`);
  console.log(`Patched CPP SHA256: ${hash(patched)}; patch SHA256: ${hash(patch)}`);
  console.log(`Selection truth table: ${cases} cases; ${changed} intended SSAO-only Web case differs. Real depth consumers, prepass, internal depth and post/MSAA resolve code unchanged.`);
  console.log('SSAO_DEPTH_COPY_SOURCE_CHECK: PASS');
  console.log('Source contract only: remote original/patched visual and GL lifecycle tests (depth/screen consumers, MSAA, resize) and matched hardware measurements remain required. No engine, driver, visual or FPS proof.');
}

try { main(); }
catch (error) { console.error(`SSAO_DEPTH_COPY_SOURCE_CHECK: FAIL: ${error.message}`); process.exitCode = 1; }
