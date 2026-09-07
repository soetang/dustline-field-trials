'use strict';

// CPU-only guard tests; importing the runner cannot start browsers or builds.
const assert = require('node:assert/strict');
const {requireRemoteRunner, captureDirectory, validateEngine} = require('./engine-depth-copy-review');
let checks = 0;
const check = action => { action(); checks++; };
const runner = {GITHUB_ACTIONS:'true', RUNNER_ENVIRONMENT:'github-hosted', RUNNER_OS:'Linux'};
check(() => requireRemoteRunner(runner));
for (const field of Object.keys(runner)) {
  const env = {...runner};
  delete env[field];
  check(() => assert.throws(() => requireRemoteRunner(env)));
}
check(() => assert.throws(() => requireRemoteRunner({...runner, RUNNER_ENVIRONMENT:'self-hosted'})));
check(() => assert.equal(captureDirectory(['map-review-browser-old'], ['other', 'map-review-browser-old', 'map-review-browser-new123']), 'map-review-browser-new123'));
for (const names of [[], ['map-review-browser-../outside'], ['map-review-browser-one', 'map-review-browser-two']])
  check(() => assert.throws(() => captureDirectory([], names)));

const templates = {schema:1, templates:{baseline:{js_sha256:'a'.repeat(64), wasm_sha256:'b'.repeat(64)}, patched:{js_sha256:'c'.repeat(64), wasm_sha256:'d'.repeat(64)}}};
for (const mode of ['baseline', 'patched']) {
  const review = {staged:true, depth_copy_review:true, expected_patch:mode === 'patched', engine:{...templates.templates[mode]}};
  check(() => validateEngine(review, templates, mode));
  const mapReview = {...review, depth_copy_review:false, engine_map_review:true};
  check(() => validateEngine(mapReview, templates, mode, 'engine-map'));
  check(() => assert.throws(() => validateEngine(mapReview, templates, mode)));
  check(() => assert.throws(() => validateEngine(review, templates, mode, 'engine-map')));
  check(() => assert.throws(() => validateEngine(review, templates, mode, 'unknown')));
  for (const field of ['staged', 'depth_copy_review', 'expected_patch'])
    check(() => assert.throws(() => validateEngine({...review, [field]:!review[field]}, templates, mode)));
  for (const field of ['js_sha256', 'wasm_sha256'])
    check(() => assert.throws(() => validateEngine({...review, engine:{...review.engine, [field]:'e'.repeat(64)}}, templates, mode)));
  const identical = structuredClone(templates);
  identical.templates.patched.wasm_sha256 = identical.templates.baseline.wasm_sha256;
  check(() => assert.throws(() => validateEngine(review, identical, mode)));
}
console.log(`PASS: ${checks} remote matched-engine orchestration guards (no browser/compiler).`);
