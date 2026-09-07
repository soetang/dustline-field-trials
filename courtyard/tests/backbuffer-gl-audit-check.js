'use strict';
const assert = require('node:assert/strict');
const {installCanvasHook} = require('../engine/experiments/backbuffer-gl-audit');

// No browser/GPU needed. Verify the observer's forwarding and counters; this
// does not establish native framebuffer correctness or replace the Web fixture.
const methods = ['checkFramebufferStatus', 'createFramebuffer', 'deleteFramebuffer',
  'createTexture', 'deleteTexture', 'texImage2D', 'texImage3D', 'texStorage2D',
  'texStorage3D', 'copyTexImage2D', 'renderbufferStorage', 'renderbufferStorageMultisample',
  'framebufferTexture2D', 'framebufferTextureLayer', 'framebufferRenderbuffer', 'blitFramebuffer'];
let checks = 0;
function equal(actual, expected) { assert.deepEqual(actual, expected); checks++; }
function makeGL() {
  const gl = {calls: [], result: {}, error: null};
  for (const name of methods) gl[name] = function (...args) {
    this.calls.push({name, args});
    if (this.error) throw this.error;
    return this.result;
  };
  gl.getError = gl.getParameter = () => { throw new Error('Observer must not query driver'); };
  return gl;
}
const gl = makeGL(), other = makeGL();
const prototype = {getContext(type, options) { this.request = [type, options]; return this.context; }};
const canvas = Object.assign(Object.create(prototype), {id: 'canvas', context: gl});
const unrelated = Object.assign(Object.create(prototype), {id: 'unrelated', context: other});
const audit = installCanvasHook(prototype);
const options = {alpha: false};
equal(canvas.getContext('webgl2', options), gl);
equal(canvas.request, ['webgl2', options]);
const wrapped = gl.blitFramebuffer;
canvas.getContext('webgl2');
equal(gl.blitFramebuffer, wrapped);
unrelated.getContext('webgl2');
other.checkFramebufferStatus(1);
equal(audit.snapshot().contexts, 1);
equal(audit.snapshot().totals.checks, 0);

for (const name of methods) {
  audit.reset();
  const args = [{identity: name}, 2, 3];
  equal(gl[name](...args), gl.result);
  equal(gl.calls.at(-1), {name, args});
  equal(audit.snapshot().calls[name], 1);
  const failure = new Error(name);
  gl.error = failure;
  assert.throws(() => gl[name](...args), error => error === failure); checks++;
  equal(audit.snapshot().totals.exceptions, 1);
  equal(audit.snapshot().calls[name], 2);
  gl.error = null;
  // Borrowing a wrapped method keeps its original receiver semantics and
  // must not count as work on the owned context.
  equal(gl[name].call(other, ...args), other.result);
  equal(audit.snapshot().calls[name], 2);
}
audit.reset(); gl.result = 0x8cd5;
gl.checkFramebufferStatus(0x8d40);
equal(audit.snapshot().totals.complete, 1);
for (let i = 0; i < 20; i++) { gl.result = 100 + i; gl.checkFramebufferStatus(0x8d40); }
gl.result = 100; gl.checkFramebufferStatus(0x8d40);
let state = audit.snapshot();
equal(state.incomplete_statuses.length, 16);
equal(state.incomplete_statuses[0].count, 2);
equal(state.incomplete_status_overflow, 4);
equal(state.totals.incomplete, 21);
state.incomplete_statuses[0].count = 0; state.totals.checks = 0;
equal(audit.snapshot().incomplete_statuses[0].count, 2);
equal(audit.snapshot().totals.checks, 22);

audit.reset();
for (const name of ['texImage2D', 'texImage3D', 'texStorage2D', 'texStorage3D', 'copyTexImage2D']) {
  gl[name](0, 0, 0x88f0);
  gl[name](0, 0, 0x8058);
}
gl.texImage2D(0, 0, {valueOf() { throw new Error('No extra coercion'); }});
for (const name of ['framebufferTexture2D', 'framebufferTextureLayer', 'framebufferRenderbuffer']) {
  gl[name](0, 0x8ce0); gl[name](0, 0x821a);
}
for (const count of [0, 1, 2, 4, 8, 16]) gl.renderbufferStorageMultisample(0, count);
gl.blitFramebuffer(0, 0, 0, 0, 0, 0, 0, 0, 0x4500, 0);
state = audit.snapshot();
equal(state.totals.texture_allocations, 11);
equal(state.totals.depth_texture_allocations, 5);
equal(state.totals.color_texture_allocations, 5);
equal(state.totals.unknown_texture_allocations, 1);
equal(state.totals.attachments, 6);
equal(state.totals.color_attachments, 3);
equal(state.totals.depth_attachments, 3);
equal(state.totals.stencil_attachments, 3);
equal(state.multisample_samples, {0: 1, 1: 1, 2: 1, 4: 1, 8: 1, other: 1});
equal([state.totals.blits, state.totals.color_blits, state.totals.depth_blits, state.totals.stencil_blits], [1, 1, 1, 1]);
equal(state.adds_driver_queries, false);
equal(state.consumes_get_error, false);
audit.reset();
equal(audit.snapshot().contexts, 1);
equal(Object.values(audit.snapshot().totals).every(value => value === 0), true);
console.log(`BACKBUFFER_GL_AUDIT: ${checks}/${checks} passed`);
