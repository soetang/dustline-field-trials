'use strict';

// Remote correctness review, not a hardware benchmark or deployment command.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

function requireRemoteRunner(env) {
  assert.equal(env.GITHUB_ACTIONS, 'true', 'Run renderer reviews on GitHub, never the user desktop');
  assert.equal(env.RUNNER_ENVIRONMENT, 'github-hosted', 'Use an isolated hosted runner');
  assert.equal(env.RUNNER_OS, 'Linux');
}

function captureDirectory(before, after) {
  const added = after.filter(name => !before.includes(name) && /^map-review-browser-[A-Za-z0-9]+$/.test(name));
  assert.equal(added.length, 1, 'Exactly one new isolated capture directory');
  return added[0];
}

function validateEngine(review, templates, mode, kind = 'depth-copy') {
  assert(['baseline', 'patched'].includes(mode));
  assert(['depth-copy', 'engine-map'].includes(kind));
  assert.equal(templates.schema, 1);
  assert.equal(review.expected_patch, mode === 'patched');
  assert.equal(review.staged, true);
  assert.equal(review[kind === 'engine-map' ? 'engine_map_review' : 'depth_copy_review'], true);
  for (const field of ['js_sha256', 'wasm_sha256']) {
    assert.match(templates.templates[mode][field], /^[a-f0-9]{64}$/);
    assert.equal(review.engine[field], templates.templates[mode][field], `Actual exported ${mode} ${field} matches verified template`);
  }
  assert.notEqual(templates.templates.baseline.wasm_sha256, templates.templates.patched.wasm_sha256,
    'The original and patched engines are distinct');
}

function run(manifestPath, kind) {
  requireRemoteRunner(process.env);
  assert(['depth-copy', 'engine-map'].includes(kind));
  const root = path.resolve(__dirname, '../..');
  const artifacts = path.join(root, 'artifacts');
  const output = path.join(artifacts, 'engine-comparison');
  fs.mkdirSync(output, {recursive:true});
  const templates = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const directories = {};
  for (const mode of ['baseline', 'patched']) {
    const template = templates.templates[mode].path;
    assert.equal(path.dirname(template), fs.realpathSync(path.join(artifacts, 'engine-templates')));
    assert.equal(path.basename(template), mode === 'baseline' ? 'baseline-web-nothreads.zip' : 'remove-ssao-depth-copy-web-nothreads.zip');
    const before = fs.readdirSync(artifacts);
    const args = [path.join(__dirname, 'map-review-browser.js'), `--${kind}-review`, '--capture', `--engine-template=${template}`];
    if (mode === 'patched') args.push('--expect-ssao-depth-copy-removed');
    const result = spawnSync(process.execPath, args, {cwd:root, encoding:'utf8', timeout:15 * 60 * 1000, maxBuffer:16 * 1024 * 1024});
    const log = (result.stdout || '') + (result.stderr || '') + (result.error ? String(result.error) : '');
    fs.writeFileSync(path.join(output, `${mode}.log`), log);
    process.stdout.write(log);
    // Record failed captures too: they are evidence, not a passing comparison.
    const directory = path.join(artifacts, captureDirectory(before, fs.readdirSync(artifacts)));
    assert.equal(fs.realpathSync(directory), directory, 'Capture output must not be a symlink');
    directories[mode] = directory;
    fs.writeFileSync(path.join(output, 'captures.json'), JSON.stringify(directories, null, 2) + '\n');
    assert.equal(result.status, 0, `${mode} renderer fixture succeeded (see saved log)`);
    validateEngine(JSON.parse(fs.readFileSync(path.join(directory, 'captures.json'), 'utf8')), templates, mode, kind);
  }
  const {PNG} = require('playwright-core/lib/utilsBundle');
  const readReview = mode => JSON.parse(fs.readFileSync(path.join(directories[mode], 'captures.json'), 'utf8'));
  const readImage = mode => capture => PNG.sync.read(fs.readFileSync(path.join(directories[mode], `${capture.name}.png`)));
  const comparison = require(`./${kind}-review`).compareReviews(readReview('baseline'), readReview('patched'), readImage('baseline'), readImage('patched'));
  fs.writeFileSync(path.join(output, 'comparison.json'), JSON.stringify(comparison, null, 2) + '\n');
  console.log('PASS: matched-engine pixels and depth-copy correctness. This does not establish hardware FPS.');
  return comparison;
}

module.exports = {requireRemoteRunner, captureDirectory, validateEngine};
if (require.main === module) {
  try {
    assert(process.argv.length === 3 || (process.argv.length === 4 && process.argv[3] === '--map'),
      'Usage: engine-depth-copy-review.js VERIFIED_TEMPLATES_JSON [--map]');
    run(path.resolve(process.argv[2]), process.argv.includes('--map') ? 'engine-map' : 'depth-copy');
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  }
}
