'use strict';

// Optional source-level engine experiment. Not part of normal CI and never builds
// Godot: compile the actual pinned function bodies against the adjacent GL mock.
// Usage: node native-godot/tests/engine-backbuffer-check.js [--source PATH]
// PATH may be the pinned source tree or its render_scene_buffers_gles3.cpp backup.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const relativeSource = 'drivers/gles3/storage/render_scene_buffers_gles3.cpp';
const pinnedHash = 'eed85d446a818f3ffbdac02b3461f297fb40f58cf938aea88b3a641cb0b47155';
const hash = text => crypto.createHash('sha256').update(text).digest('hex');
const usage = 'Usage: node native-godot/tests/engine-backbuffer-check.js [--source PATH]';

function applyHunks(source, patch, reverse = false) {
  const lines = patch.trimEnd().split('\n');
  assert.equal(lines[0], `--- a/${relativeSource}`, 'Unexpected patch target');
  assert.equal(lines[1], `+++ b/${relativeSource}`, 'Unexpected patch target');
  let result = source, count = 0;
  for (let i = 2; i < lines.length;) {
    const header = /^@@ -(\d+),(\d+) \+(\d+),(\d+) @@$/.exec(lines[i++]);
    assert(header, 'Unsupported patch hunk header');
    const before = [], after = [];
    while (i < lines.length && !lines[i].startsWith('@@')) {
      const line = lines[i++], prefix = line[0];
      assert([' ', '+', '-'].includes(prefix), 'Unsupported patch line');
      if (prefix !== '+') before.push(line.slice(1));
      if (prefix !== '-') after.push(line.slice(1));
    }
    assert.equal(before.length, Number(header[2]), 'Incorrect old hunk length');
    assert.equal(after.length, Number(header[4]), 'Incorrect new hunk length');
    const from = '\n' + (reverse ? after : before).join('\n') + '\n';
    const to = '\n' + (reverse ? before : after).join('\n') + '\n';
    const at = result.indexOf(from);
    assert(at >= 0 && result.indexOf(from, at + 1) === -1,
      'Patch must match exactly once; no fuzzy or offset-content substitutions');
    result = result.slice(0, at) + to + result.slice(at + from.length);
    count++;
  }
  assert(count > 0, 'No patch hunks');
  return result;
}

function extract(source, name) {
  // The hash pins Godot's formatting as well as its code. Its method-closing
  // brace is at column zero; nested/preprocessor alternative braces are indented.
  // Counting braces would misread the mutually exclusive IOS branches.
  const expression = new RegExp(`^void RenderSceneBuffersGLES3::${name}\\([^]*?^\\}`, 'gm');
  const matches = [...source.matchAll(expression)];
  assert.equal(matches.length, 1, `Expected one complete ${name} definition`);
  return matches[0][0];
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 60_000 });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} failed (${result.signal || result.status})`);
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
    console.log(`SKIP: Optional pinned Godot source is absent: ${sourceFile}`);
    console.log('Provide the official 4.7.2-stable source tree or its pristine CPP backup with --source PATH. Nothing is downloaded or installed.');
    return;
  }

  const input = fs.readFileSync(sourceFile, 'utf8');
  const patchFile = path.join(root, 'native-godot/engine/patches/cache-backbuffer-validation.patch');
  const patch = fs.readFileSync(patchFile, 'utf8');
  let original = input, inputPatched = false;
  if (hash(original) !== pinnedHash) {
    original = applyHunks(input, patch, true);
    inputPatched = true;
  }
  assert.equal(hash(original), pinnedHash,
    'Source is not the audited pristine Godot 4.7.2 CPP. Review upstream changes before changing this pin.');
  const patched = applyHunks(original, patch);
  assert.equal(applyHunks(patched, patch, true), original, 'Patch must round-trip exactly');
  if (inputPatched) assert.equal(patched, input, 'Only the exact experiment patch may differ');

  // Exercise the real clear body below, and verify the surrounding configure
  // contract directly. The fixture does not claim to execute full configure().
  const configure = extract(original, 'configure');
  assert(configure.indexOf('free_render_buffer_data();') >= 0);
  assert(configure.indexOf('free_render_buffer_data();') < configure.indexOf('internal_size ='));
  assert.match(extract(original, 'free_render_buffer_data'), /_clear_back_buffers\(\);/);
  assert.equal(extract(original, 'configure'), extract(patched, 'configure'));
  assert.equal(extract(original, '_clear_back_buffers'), extract(patched, '_clear_back_buffers'));

  const definitions = [[original, 'OriginalBuffers'], [patched, 'PatchedBuffers']]
    .flatMap(([source, name]) => ['check_backbuffer', '_clear_back_buffers']
      .map(method => extract(source, method).replace(`RenderSceneBuffersGLES3::${method}`, `${name}::${method}`)))
    .join('\n\n');
  const fixture = fs.readFileSync(path.join(__dirname, 'engine-backbuffer-fixture.cpp'), 'utf8');
  assert.equal(fixture.split('// @EXTRACTED_FUNCTIONS@').length, 2);
  const artifactRoot = path.join(root, 'artifacts');
  fs.mkdirSync(artifactRoot, { recursive: true });
  const artifact = fs.mkdtempSync(path.join(artifactRoot, 'engine-backbuffer-check-'));
  const cpp = path.join(artifact, 'backbuffer.cpp');
  const binary = path.join(artifact, 'backbuffer-check');
  fs.writeFileSync(cpp, fixture.replace('// @EXTRACTED_FUNCTIONS@', () => definitions));
  const compiler = process.env.CXX || 'c++';
  const flags = ['-std=c++17', '-O0', '-Wall', '-Wextra', '-Werror', '-DWEB_ENABLED', cpp, '-o', binary];
  fs.writeFileSync(path.join(artifact, 'manifest.json'), JSON.stringify({
    sourceFile, originalSha256: hash(original), patchedSha256: hash(patched),
    patchSha256: hash(patch), fixtureSha256: hash(fixture), inputPatched,
    compiler, flags, limitations: 'Mock GL, not a GPU/browser/driver test. Configure ordering is checked statically; actual clear and check bodies execute.',
  }, null, 2) + '\n');
  console.log(`Artifacts: ${artifact}`);
  console.log(`Source: ${inputPatched ? 'exact patch reversed in memory' : 'pristine pinned backup'}; SHA-256 ${pinnedHash}`);
  run(compiler, flags, artifact);
  run(binary, [], artifact);
  assert.equal(fs.readFileSync(sourceFile, 'utf8'), input, 'Pinned source changed during test');
  assert.equal(fs.readFileSync(patchFile, 'utf8'), patch, 'Patch changed during test');
  console.log('No source checkout or runtime modified. Context-loss divergence is expected; this does not establish driver correctness or a performance gain.');
}

try { main(); }
catch (error) { console.error(`FAIL: ${error.message}`); process.exitCode = 1; }
