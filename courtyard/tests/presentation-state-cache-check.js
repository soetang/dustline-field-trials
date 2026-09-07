'use strict';

// Node-only contract tests; no browser, renderer, engine import, or compilation.
// This is a deliberately small WebGL2 state model, not a WebGL implementation.
// Relevant semantics: https://registry.khronos.org/webgl/specs/latest/1.0/#5.14.6
// and https://registry.khronos.org/webgl/specs/latest/2.0/ (framebuffer bindings).
const assert = require('node:assert/strict');
const { install } = require('../engine/experiments/presentation-state-cache');

const GL = Object.freeze({
  SCISSOR_TEST: 0x0c11, BLEND: 0x0be2, DEPTH_TEST: 0x0b71, CULL_FACE: 0x0b44,
  FRAMEBUFFER: 0x8d40, READ_FRAMEBUFFER: 0x8ca8, DRAW_FRAMEBUFFER: 0x8ca9,
  FRAMEBUFFER_BINDING: 0x8ca6, DRAW_FRAMEBUFFER_BINDING: 0x8ca6,
  READ_FRAMEBUFFER_BINDING: 0x8caa, VIEWPORT: 0x0ba2, MAX_TEXTURE_SIZE: 0x0d33,
  NO_ERROR: 0, INVALID_ENUM: 0x0500, INVALID_OPERATION: 0x0502,
  CONTEXT_LOST_WEBGL: 0x9242,
});
const contexts = new WeakSet();
const framebuffers = new WeakMap();
class Framebuffer {}
class Canvas {
  constructor() { this.listeners = new Map(); }
  addEventListener(name, fn) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(fn);
  }
  removeEventListener(name, fn) { this.listeners.get(name)?.delete(fn); }
  dispatch(name) {
    const event = { type: name, target: this, preventDefault() { this.defaultPrevented = true; } };
    for (const listener of this.listeners.get(name) || []) listener.call(this, event);
  }
}
function enter(receiver, method, args) {
  if (!contexts.has(receiver)) throw new TypeError('Illegal invocation');
  receiver.calls[method] = (receiver.calls[method] || 0) + 1;
  receiver.lastArgs[method] = args;
  if (receiver.throwNext.has(method)) {
    const error = receiver.throwNext.get(method);
    receiver.throwNext.delete(method);
    throw error;
  }
}
function enumValue(value) {
  // Unary plus follows ToNumber, including rejecting boxed/primitive BigInt.
  return (+value) >>> 0;
}
function framebufferValue(value) {
  if (value == null) return null;
  if (!framebuffers.has(value)) throw new TypeError('Not a WebGLFramebuffer');
  return framebuffers.get(value);
}
class FakeGL {
  constructor() {
    contexts.add(this);
    Object.assign(this, GL);
    this.canvas = new Canvas();
    this.calls = Object.create(null);
    this.lastArgs = Object.create(null);
    this.throwNext = new Map();
    this.errors = new Set();
    this.generation = 1;
    this.lost = false;
    this.resetState();
  }
  resetState() {
    this.caps = new Set();
    this.read = null;
    this.draw = null;
    this.viewportValue = new Int32Array([0, 0, 640, 480]);
  }
  getParameter(pname) {
    enter(this, 'getParameter', [...arguments]);
    if (arguments.length < 1) throw new TypeError('Missing pname');
    const name = enumValue(pname);
    if (this.lost) return null;
    if ([GL.SCISSOR_TEST, GL.BLEND, GL.DEPTH_TEST, GL.CULL_FACE].includes(name)) return this.caps.has(name);
    if (name === GL.DRAW_FRAMEBUFFER_BINDING) return this.draw;
    if (name === GL.READ_FRAMEBUFFER_BINDING) return this.read;
    if (name === GL.VIEWPORT) return new Int32Array(this.viewportValue);
    if (name === GL.MAX_TEXTURE_SIZE) return 16384;
    this.errors.add(GL.INVALID_ENUM);
    return null;
  }
  enable(cap) {
    enter(this, 'enable', [...arguments]);
    if (arguments.length < 1) throw new TypeError('Missing capability');
    const value = enumValue(cap);
    if (this.lost) return;
    if (![GL.SCISSOR_TEST, GL.BLEND, GL.DEPTH_TEST, GL.CULL_FACE].includes(value)) {
      this.errors.add(GL.INVALID_ENUM); return;
    }
    this.caps.add(value);
  }
  disable(cap) {
    enter(this, 'disable', [...arguments]);
    if (arguments.length < 1) throw new TypeError('Missing capability');
    const value = enumValue(cap);
    if (this.lost) return;
    if (![GL.SCISSOR_TEST, GL.BLEND, GL.DEPTH_TEST, GL.CULL_FACE].includes(value)) {
      this.errors.add(GL.INVALID_ENUM); return;
    }
    this.caps.delete(value);
  }
  createFramebuffer() {
    enter(this, 'createFramebuffer', [...arguments]);
    if (this.lost) return null;
    const object = new Framebuffer();
    framebuffers.set(object, { owner: this, generation: this.generation, deleted: false });
    return object;
  }
  bindFramebuffer(target, framebuffer) {
    enter(this, 'bindFramebuffer', [...arguments]);
    if (arguments.length < 2) throw new TypeError('Missing framebuffer');
    const value = enumValue(target);
    const data = framebufferValue(framebuffer);
    if (this.lost) return;
    if (![GL.FRAMEBUFFER, GL.READ_FRAMEBUFFER, GL.DRAW_FRAMEBUFFER].includes(value)) {
      this.errors.add(GL.INVALID_ENUM); return;
    }
    if (data && (data.owner !== this || data.deleted || data.generation !== this.generation)) {
      this.errors.add(GL.INVALID_OPERATION); return;
    }
    const object = data ? framebuffer : null;
    if (value !== GL.READ_FRAMEBUFFER) this.draw = object;
    if (value !== GL.DRAW_FRAMEBUFFER) this.read = object;
  }
  deleteFramebuffer(framebuffer) {
    enter(this, 'deleteFramebuffer', [...arguments]);
    if (arguments.length < 1) throw new TypeError('Missing framebuffer');
    const data = framebufferValue(framebuffer);
    if (this.lost || !data) return;
    if (data.owner !== this || data.generation !== this.generation) {
      this.errors.add(GL.INVALID_OPERATION); return;
    }
    if (data.deleted) return;
    data.deleted = true;
    if (this.draw === framebuffer) this.draw = null;
    if (this.read === framebuffer) this.read = null;
  }
  getError() {
    enter(this, 'getError', [...arguments]);
    const error = this.errors.values().next().value ?? GL.NO_ERROR;
    this.errors.delete(error);
    return error;
  }
  isContextLost() {
    enter(this, 'isContextLost', [...arguments]);
    return this.lost;
  }
  viewport(x, y, width, height) {
    enter(this, 'viewport', [...arguments]);
    this.viewportValue = new Int32Array([x, y, width, height]);
  }
  blitFramebuffer() { enter(this, 'blitFramebuffer', [...arguments]); }
  loseContext(notify = true) {
    this.lost = true;
    this.errors.clear();
    this.errors.add(GL.CONTEXT_LOST_WEBGL);
    if (notify) this.canvas.dispatch('webglcontextlost');
  }
  restoreContext() {
    this.lost = false;
    this.generation++;
    this.errors.clear();
    this.resetState();
    this.canvas.dispatch('webglcontextrestored');
  }
}

let checks = 0;
let failed = 0;
function check(label, fn) {
  checks++;
  try { fn(); }
  catch (error) { failed++; console.error(`FAIL: ${label}\n${error.stack}`); }
}
function equal(actual, expected, label) { check(label, () => assert.strictEqual(actual, expected)); }
function count(gl, method) { return gl.calls[method] || 0; }
function fixture(enabled = true) {
  const gl = new FakeGL();
  const controller = install(gl);
  equal(count(gl, 'getParameter'), 0, 'installation performs no initial driver queries');
  assert(controller && typeof controller.setEnabled === 'function', 'install must return setEnabled controller');
  controller.setEnabled(enabled);
  return { gl, controller };
}
function state(gl, label) {
  equal(gl.getParameter(GL.SCISSOR_TEST), gl.lost ? null : gl.caps.has(GL.SCISSOR_TEST), `${label}: scissor`);
  equal(gl.getParameter(GL.DRAW_FRAMEBUFFER_BINDING), gl.lost ? null : gl.draw, `${label}: draw binding`);
  equal(gl.getParameter(GL.FRAMEBUFFER_BINDING), gl.lost ? null : gl.draw, `${label}: framebuffer alias`);
  equal(gl.getParameter(GL.READ_FRAMEBUFFER_BINDING), gl.lost ? null : gl.read, `${label}: read binding`);
}
function throwsSame(gl, method, args, label) {
  const marker = new Error(label);
  gl.throwNext.set(method, marker);
  check(label, () => assert.throws(() => gl[method](...args), error => error === marker));
  state(gl, `${label}: no poisoned cache`);
}

check('fake model has FRAMEBUFFER / DRAW alias and separate READ state', () => {
  const gl = new FakeGL(), a = gl.createFramebuffer(), b = gl.createFramebuffer();
  gl.bindFramebuffer(GL.FRAMEBUFFER, a);
  gl.bindFramebuffer(GL.READ_FRAMEBUFFER, b);
  assert.equal(gl.getParameter(GL.FRAMEBUFFER_BINDING), a);
  assert.equal(gl.getParameter(GL.READ_FRAMEBUFFER_BINDING), b);
  gl.deleteFramebuffer(a);
  assert.equal(gl.draw, null);
  assert.equal(gl.read, b);
});

{
  const gl = new FakeGL();
  const controller = install(gl);
  let start = count(gl, 'getParameter');
  gl.getParameter(GL.SCISSOR_TEST); gl.getParameter(GL.DRAW_FRAMEBUFFER_BINDING);
  equal(count(gl, 'getParameter') - start, 2, 'installation starts with native getters disabled control');
  controller.setEnabled(true);
  state(gl, 'initial enabled state');
  start = count(gl, 'getParameter');
  for (let i = 0; i < 20; i++) {
    gl.getParameter(GL.SCISSOR_TEST);
    gl.getParameter(GL.DRAW_FRAMEBUFFER_BINDING);
    gl.getParameter(GL.FRAMEBUFFER_BINDING);
  }
  equal(count(gl, 'getParameter') - start, 0, 'known cached queries avoid original getParameter');
  equal(count(gl, 'getError'), 0, 'installation and cache hits never consume errors');
  gl.enable(GL.SCISSOR_TEST); state(gl, 'enable scissor');
  gl.disable(GL.SCISSOR_TEST); state(gl, 'disable scissor');
  gl.enable(GL.BLEND); gl.enable(GL.DEPTH_TEST); gl.disable(GL.CULL_FACE);
  equal(gl.getParameter(GL.BLEND), true, 'unrelated enabled capability preserved');
  equal(gl.getParameter(GL.DEPTH_TEST), true, 'second unrelated capability preserved');
  start = count(gl, 'getParameter');
  gl.getParameter(GL.BLEND); gl.getParameter(GL.VIEWPORT); gl.getParameter(GL.MAX_TEXTURE_SIZE);
  equal(count(gl, 'getParameter') - start, 3, 'unrelated queries always reach original getter');
  equal(gl.viewport, FakeGL.prototype.viewport, 'viewport method untouched');
  equal(gl.blitFramebuffer, FakeGL.prototype.blitFramebuffer, 'blit method untouched');
  equal(gl.getError, FakeGL.prototype.getError, 'getError method untouched');
  gl.viewport(1, 2, 300, 200);
  check('unrelated typed-array query value preserved', () => assert.deepEqual(gl.getParameter(GL.VIEWPORT), new Int32Array([1, 2, 300, 200])));
}

{
  const { gl } = fixture();
  const a = gl.createFramebuffer(), b = gl.createFramebuffer(), c = gl.createFramebuffer();
  for (const [target, framebuffer, label] of [
    [GL.FRAMEBUFFER, a, 'bind both'], [GL.READ_FRAMEBUFFER, b, 'bind only read'],
    [GL.DRAW_FRAMEBUFFER, c, 'bind only draw'], [GL.READ_FRAMEBUFFER, null, 'clear only read'],
    [GL.DRAW_FRAMEBUFFER, null, 'clear only draw'], [GL.FRAMEBUFFER, b, 'rebind both'],
    [GL.FRAMEBUFFER, null, 'clear both'], [GL.FRAMEBUFFER, a, 'rebind live handle'],
  ]) { gl.bindFramebuffer(target, framebuffer); state(gl, label); }
  gl.bindFramebuffer(GL.READ_FRAMEBUFFER, b);
  gl.deleteFramebuffer(a); state(gl, 'delete currently draw-bound only');
  gl.deleteFramebuffer(b); state(gl, 'delete currently read-bound only');
  gl.bindFramebuffer(GL.FRAMEBUFFER, c);
  gl.deleteFramebuffer(c); state(gl, 'delete bound to both');
  gl.deleteFramebuffer(c); gl.deleteFramebuffer(null); state(gl, 'delete repeated and null are no-ops');
  equal(gl.getError(), GL.NO_ERROR, 'valid binding/deletion sequence retains no errors');
}

{
  const { gl } = fixture();
  const other = new FakeGL(), foreign = other.createFramebuffer();
  const live = gl.createFramebuffer(), deleted = gl.createFramebuffer();
  gl.deleteFramebuffer(deleted);
  gl.bindFramebuffer(GL.FRAMEBUFFER, live);
  for (const [method, args, error, label] of [
    ['enable', [0xfefef], GL.INVALID_ENUM, 'invalid enable enum'],
    ['disable', [0xfefef], GL.INVALID_ENUM, 'invalid disable enum'],
    ['bindFramebuffer', [0xfefef, live], GL.INVALID_ENUM, 'invalid framebuffer target'],
    ['bindFramebuffer', [GL.DRAW_FRAMEBUFFER, foreign], GL.INVALID_OPERATION, 'cross-context bind'],
    ['bindFramebuffer', [GL.FRAMEBUFFER, deleted], GL.INVALID_OPERATION, 'deleted framebuffer bind'],
    ['deleteFramebuffer', [foreign], GL.INVALID_OPERATION, 'cross-context deletion'],
  ]) {
    const errorReads = count(gl, 'getError');
    gl[method](...args);
    state(gl, label);
    equal(count(gl, 'getError'), errorReads, `${label}: wrapper does not consume native error`);
    equal(gl.getError(), error, `${label}: exact native error remains available`);
    equal(gl.getError(), GL.NO_ERROR, `${label}: no extra errors`);
  }
  for (const [method, args] of [
    ['bindFramebuffer', [GL.FRAMEBUFFER, {}]], ['bindFramebuffer', [GL.FRAMEBUFFER, Object.create(Framebuffer.prototype)]],
    ['deleteFramebuffer', [{}]], ['enable', []], ['disable', []], ['bindFramebuffer', [GL.FRAMEBUFFER]],
    ['deleteFramebuffer', []], ['getParameter', []], ['enable', [Symbol('cap')]],
    ['enable', [1n]], ['enable', [Object(1n)]], ['getParameter', [Symbol('pname')]],
  ]) {
    check(`${method}: native argument TypeError preserved`, () => assert.throws(() => gl[method](...args), TypeError));
    state(gl, `${method}: state after rejected arguments`);
  }
  const errorReads = count(gl, 'getError');
  equal(gl.getParameter(0xdead), null, 'unknown pname returns native null');
  state(gl, 'unknown query does not corrupt known state');
  equal(count(gl, 'getError'), errorReads, 'unknown query error not consumed');
  equal(gl.getError(), GL.INVALID_ENUM, 'unknown query INVALID_ENUM retained');
}

{
  const { gl, controller } = fixture();
  const a = gl.createFramebuffer();
  state(gl, 'warm before coercion');
  gl.enable(String(GL.SCISSOR_TEST)); state(gl, 'numeric-string enable');
  gl.disable(new Number(GL.SCISSOR_TEST)); state(gl, 'boxed-number disable');
  gl.enable(GL.SCISSOR_TEST + 0.5); state(gl, 'fractional numeric capability truncates to scissor');
  gl.disable(GL.SCISSOR_TEST + 2 ** 32); state(gl, 'oversized numeric capability wraps to scissor');
  gl.enable(GL.SCISSOR_TEST - 2 ** 32); state(gl, 'negative numeric capability wraps to scissor');
  gl.bindFramebuffer(String(GL.DRAW_FRAMEBUFFER), a); state(gl, 'numeric-string framebuffer target');
  gl.bindFramebuffer(GL.FRAMEBUFFER, undefined); state(gl, 'nullable undefined framebuffer');
  let conversions = 0;
  gl.enable({ valueOf() { conversions++; return GL.SCISSOR_TEST; } });
  equal(conversions, 1, 'capability object is coerced exactly once');
  state(gl, 'object capability coercion');
  conversions = 0;
  equal(gl.getParameter({ valueOf() { conversions++; return GL.SCISSOR_TEST; } }), true, 'object query uses native coercion');
  equal(conversions, 1, 'query object is coerced exactly once');
  gl.disable(GL.SCISSOR_TEST, 'extra');
  equal(gl.lastArgs.disable.length, 2, 'extra arguments forwarded to original method');
  state(gl, 'extra-argument capability mutation');
  for (const method of ['enable', 'disable', 'createFramebuffer', 'bindFramebuffer', 'deleteFramebuffer']) {
    const args = method === 'enable' || method === 'disable' ? [GL.SCISSOR_TEST]
      : method === 'bindFramebuffer' ? [GL.FRAMEBUFFER, a] : method === 'deleteFramebuffer' ? [a] : [];
    throwsSame(gl, method, args, `${method}: original exception identity preserved`);
  }
  controller.setEnabled(false);
  throwsSame(gl, 'getParameter', [GL.SCISSOR_TEST], 'disabled getter exception identity preserved');
  controller.setEnabled(true);
  controller.invalidate();
  throwsSame(gl, 'getParameter', [GL.SCISSOR_TEST], 'unknown enabled getter exception identity preserved');
  const recursiveError = new Error('recursive coercion');
  check('throwing coercion retains nested mutation and exception', () => assert.throws(() => gl.disable({ valueOf() {
    gl.enable(GL.SCISSOR_TEST);
    throw recursiveError;
  } }), error => error === recursiveError));
  state(gl, 'state after nested mutation and throwing coercion');
  equal(count(gl, 'getError'), 0, 'coercion and exception paths never probe getError');
}

{
  const { gl, controller } = fixture();
  for (let i = 0; i < 8; i++) {
    controller.setEnabled(false);
    const a = gl.createFramebuffer();
    if (i % 2) gl.enable(GL.SCISSOR_TEST); else gl.disable(GL.SCISSOR_TEST);
    gl.bindFramebuffer(GL.FRAMEBUFFER, a);
    if (i % 3 === 0) gl.deleteFramebuffer(a);
    const start = count(gl, 'getParameter');
    state(gl, `disabled round ${i}`);
    equal(count(gl, 'getParameter') - start, 4, `disabled round ${i}: native query control`);
    controller.setEnabled(true);
    state(gl, `re-enabled round ${i}`);
  }
  equal(count(gl, 'getError'), 0, 'mode toggles do not consume errors');
}

{
  // Objects made before installation are valid but are not automatically
  // trustworthy to the cache. Their original bindings must still be observed.
  const gl = new FakeGL(), preexisting = gl.createFramebuffer();
  gl.enable(GL.SCISSOR_TEST); gl.bindFramebuffer(GL.FRAMEBUFFER, preexisting);
  const controller = install(gl); controller.setEnabled(true);
  state(gl, 'pre-install nondefault state');
  gl.bindFramebuffer(GL.DRAW_FRAMEBUFFER, null);
  gl.bindFramebuffer(GL.DRAW_FRAMEBUFFER, preexisting);
  state(gl, 'unknown pre-install handle uses safe fallback');
  gl.deleteFramebuffer(preexisting);
  state(gl, 'delete unknown pre-install handle');
}

{
  const { gl } = fixture();
  const other = new FakeGL(), a = gl.createFramebuffer(), b = other.createFramebuffer();
  gl.bindFramebuffer(GL.FRAMEBUFFER, a);
  other.bindFramebuffer(GL.FRAMEBUFFER, b); other.enable(GL.SCISSOR_TEST);
  equal(gl.getParameter.call(other, GL.SCISSOR_TEST), true, 'borrowed getter reads receiving context');
  equal(gl.getParameter.call(other, GL.FRAMEBUFFER_BINDING), b, 'borrowed getter never exposes owner framebuffer');
  gl.disable.call(other, GL.SCISSOR_TEST);
  equal(other.getParameter(GL.SCISSOR_TEST), false, 'borrowed mutator affects receiving context');
  gl.bindFramebuffer.call(other, GL.FRAMEBUFFER, null);
  equal(other.getParameter(GL.FRAMEBUFFER_BINDING), null, 'borrowed bind affects receiving context');
  const borrowedCreated = gl.createFramebuffer.call(other);
  equal(framebuffers.get(borrowedCreated).owner, other, 'borrowed creation belongs to receiving context');
  gl.deleteFramebuffer.call(other, borrowedCreated);
  equal(framebuffers.get(borrowedCreated).deleted, true, 'borrowed deletion uses receiving context');
  for (const [method, args] of [['getParameter', [GL.SCISSOR_TEST]], ['enable', [GL.SCISSOR_TEST]], ['disable', [GL.SCISSOR_TEST]], ['createFramebuffer', []], ['bindFramebuffer', [GL.FRAMEBUFFER, null]], ['deleteFramebuffer', [null]]]) {
    check(`${method}: illegal borrowed receiver throws`, () => assert.throws(() => gl[method].apply({}, args), TypeError));
  }
  state(gl, 'borrowed calls leave owning cache untouched');
}

{
  const { gl: owner } = fixture();
  const { gl: borrower } = fixture();
  state(owner, 'two-context owner initial'); state(borrower, 'two-context borrower initial');
  owner.enable.call(borrower, GL.SCISSOR_TEST);
  state(borrower, 'borrowed enable invalidates receiving installed cache');
  const a = owner.createFramebuffer.call(borrower);
  owner.bindFramebuffer.call(borrower, GL.FRAMEBUFFER, a);
  state(borrower, 'borrowed binding invalidates receiving installed cache');
  owner.deleteFramebuffer.call(borrower, a);
  state(borrower, 'borrowed deletion invalidates receiving installed cache');
  state(owner, 'two installed contexts retain independent state');
}

{
  const { gl, controller } = fixture();
  const getParameter = gl.getParameter;
  equal(install(gl), controller, 'installation is idempotent');
  equal(gl.getParameter, getParameter, 'second installation does not stack wrappers');
  state(gl, 'warm before explicit invalidation');
  controller.resetStats();
  gl.getParameter(GL.SCISSOR_TEST); gl.getParameter(GL.DRAW_FRAMEBUFFER_BINDING);
  equal(controller.getStats().hits, 2, 'stats count scoped cache hits');
  equal(controller.getStats().fallbacks, 0, 'known scoped hits require no fallback');
  const saved = controller.getStats();
  saved.hits = -123;
  equal(controller.getStats().hits, 2, 'stats snapshot is not mutable internal state');
  // The documented escape hatch is essential if code deliberately bypasses
  // installed methods via native prototypes. validate must reveal, not repair.
  FakeGL.prototype.enable.call(gl, GL.SCISSOR_TEST);
  equal(controller.validate().scissor, false, 'validation detects bypassed native mutation');
  equal(controller.validate().scissor, false, 'validation does not silently repair a discrepancy');
  controller.invalidate();
  state(gl, 'explicit invalidation restores actual state after bypass');
  check('validation after invalidation agrees with native state', () => assert.deepEqual(controller.validate(), { lost: false, scissor: true, draw: true }));
  controller.resetStats();
  equal(controller.getStats().hits, 0, 'stats reset clears hits');
  equal(controller.getStats().fallbacks, 0, 'stats reset clears fallbacks');
  equal(count(gl, 'getError'), 0, 'validation and explicit invalidation do not consume errors');
}

{
  const { gl, controller } = fixture();
  const old = gl.createFramebuffer();
  gl.enable(GL.SCISSOR_TEST); gl.bindFramebuffer(GL.FRAMEBUFFER, old);
  state(gl, 'warm before context loss');
  gl.loseContext(false);
  state(gl, 'loss before queued canvas event');
  gl.canvas.dispatch('webglcontextlost');
  gl.enable(GL.SCISSOR_TEST); gl.bindFramebuffer(GL.FRAMEBUFFER, old);
  equal(gl.createFramebuffer(), null, 'creation during context loss returns native null');
  state(gl, 'notified lost context');
  controller.setEnabled(false); state(gl, 'disabled while lost');
  controller.setEnabled(true); state(gl, 'enabled while lost');
  equal(count(gl, 'getError'), 0, 'loss handling preserves pending CONTEXT_LOST_WEBGL');
  equal(gl.getError(), GL.CONTEXT_LOST_WEBGL, 'native loss error still available');
  gl.restoreContext(); state(gl, 'restoration resets bindings and scissor');
  gl.bindFramebuffer(GL.FRAMEBUFFER, old);
  state(gl, 'old-generation framebuffer rejected after restore');
  equal(gl.getError(), GL.INVALID_OPERATION, 'old-generation handle error retained');
  const fresh = gl.createFramebuffer();
  gl.bindFramebuffer(GL.FRAMEBUFFER, fresh); gl.enable(GL.SCISSOR_TEST);
  state(gl, 'new-generation handles and tracking work');
}

{
  // Reproducible state-machine coverage; compare every query with model state,
  // not with a second potentially instrumented getParameter implementation.
  const { gl, controller } = fixture();
  const other = new FakeGL(), foreign = other.createFramebuffer();
  const objects = [null];
  let seed = 0x51c1550;
  const random = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; };
  for (let i = 0; i < 600; i++) {
    const action = random() % 12;
    const target = [GL.FRAMEBUFFER, GL.READ_FRAMEBUFFER, GL.DRAW_FRAMEBUFFER][random() % 3];
    const object = objects[random() % objects.length];
    if (action === 0) objects.push(gl.createFramebuffer());
    else if (action === 1) gl.enable(GL.SCISSOR_TEST);
    else if (action === 2) gl.disable(GL.SCISSOR_TEST);
    else if (action < 6) gl.bindFramebuffer(target, object);
    else if (action === 6) gl.deleteFramebuffer(object);
    else if (action === 7) controller.setEnabled((random() & 1) !== 0);
    else if (action === 8) gl.bindFramebuffer(target, foreign);
    else if (action === 9) gl.enable(GL.BLEND);
    else if (action === 10) gl.bindFramebuffer(String(target), object);
    else { gl.loseContext(); gl.restoreContext(); }
    state(gl, `seeded transition ${i}`);
  }
  equal(count(gl, 'getError'), 0, '600 seeded transitions never consume native errors');
}

console.log(`PRESENTATION_STATE_CACHE: ${checks - failed}/${checks} passed; fake WebGL2 state/error model, 600 seeded transitions; no GPU work`);
if (failed) process.exitCode = 1;
