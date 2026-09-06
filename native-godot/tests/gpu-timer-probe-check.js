'use strict';

// Fast Node-only timer state model. Results become available only on explicit
// browser-turn advancement; reading early throws, catching accidental waits.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { createProbe } = require('../engine/experiments/gpu-timer-probe');
const EXT = Object.freeze({ TIME_ELAPSED_EXT: 0x88bf, GPU_DISJOINT_EXT: 0x8fbb, QUERY_COUNTER_BITS_EXT: 0x8864 });
const CURRENT = 0x8865, RESULT = 0x8866, AVAILABLE = 0x8867;
const contexts = new WeakSet(), queries = new WeakMap();
class Canvas {
  constructor() { this.listeners = new Map(); }
  addEventListener(name, fn) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(fn);
  }
  removeEventListener(name, fn) { this.listeners.get(name)?.delete(fn); }
  dispatch(name) { for (const fn of this.listeners.get(name) || []) fn({ type: name }); }
  count() { return [...this.listeners.values()].reduce((n, set) => n + set.size, 0); }
}
function enter(gl, name) {
  if (!contexts.has(gl)) throw new TypeError('Illegal receiver');
  gl.calls[name] = (gl.calls[name] || 0) + 1;
  if (gl.failNext === name) { gl.failNext = null; throw new Error(`Injected ${name} failure`); }
}
class FakeGL {
  constructor({ extension = true, bits = 64, latency = 2, ns = 7_500_000 } = {}) {
    contexts.add(this);
    this.canvas = new Canvas(); this.calls = {}; this.live = new Set();
    this.extension = extension; this.bits = bits; this.latency = latency; this.ns = ns;
    this.turn = 0; this.generation = 1; this.current = null; this.lost = false;
    this.disjoint = false; this.disjointAfterResult = false; this.failNext = null;
    this.appState = { drawFramebuffer: {}, readFramebuffer: {}, scissor: true, program: {} };
  }
  getExtension(name) {
    enter(this, 'getExtension');
    assert.equal(name, 'EXT_disjoint_timer_query_webgl2');
    return this.extension && !this.lost ? { ...EXT } : null;
  }
  isContextLost() { enter(this, 'isContextLost'); return this.lost; }
  getQuery(target, pname) {
    enter(this, 'getQuery');
    assert.equal(target, EXT.TIME_ELAPSED_EXT);
    if (this.lost) return null;
    if (pname === EXT.QUERY_COUNTER_BITS_EXT) return this.bits;
    assert.equal(pname, CURRENT);
    return this.current;
  }
  getParameter(pname) {
    enter(this, 'getParameter');
    assert.equal(pname, EXT.GPU_DISJOINT_EXT, 'Probe must not read app state');
    if (this.lost) return null;
    const disjoint = this.disjoint; this.disjoint = false;
    return disjoint;
  }
  createQuery() {
    enter(this, 'createQuery');
    if (this.lost || this.nullAllocation) return null;
    const query = {};
    queries.set(query, { gl: this, generation: this.generation, deleted: false, ended: false, availableTurn: Infinity, ns: this.ns });
    this.live.add(query);
    return query;
  }
  data(query) {
    const data = queries.get(query);
    assert(data && data.gl === this && data.generation === this.generation && !data.deleted, 'Valid owned current-generation query required');
    return data;
  }
  beginQuery(target, query) {
    enter(this, 'beginQuery');
    assert.equal(target, EXT.TIME_ELAPSED_EXT);
    if (this.lost) return;
    assert.equal(this.current, null, 'Must never nest or interrupt an elapsed query');
    const data = this.data(query);
    data.ended = false; data.availableTurn = Infinity; data.ns = this.ns;
    this.current = query;
  }
  endQuery(target) {
    enter(this, 'endQuery');
    assert.equal(target, EXT.TIME_ELAPSED_EXT);
    if (this.lost) return;
    assert(this.current, 'Must never end without an active query');
    const data = this.data(this.current);
    data.ended = true; data.availableTurn = this.turn + this.latency;
    this.current = null;
  }
  getQueryParameter(query, pname) {
    enter(this, 'getQueryParameter');
    if (this.lost) return null;
    const data = this.data(query);
    assert.notEqual(query, this.current, 'Must not read an active query');
    if (pname === AVAILABLE) {
      this.calls.availability = (this.calls.availability || 0) + 1;
      return data.ended && data.availableTurn <= this.turn;
    }
    assert.equal(pname, RESULT);
    this.calls.result = (this.calls.result || 0) + 1;
    assert(data.ended && data.availableTurn <= this.turn, 'Blocking/early QUERY_RESULT read is forbidden');
    if (this.disjointAfterResult) { this.disjointAfterResult = false; this.disjoint = true; }
    return data.ns;
  }
  deleteQuery(query) {
    enter(this, 'deleteQuery');
    if (this.lost) return;
    const data = this.data(query);
    assert.notEqual(this.current, query, 'Own active query must be ended explicitly before deletion');
    data.deleted = true; this.live.delete(query);
  }
  blitFramebuffer() { enter(this, 'blitFramebuffer'); return 71; }
  getError() { enter(this, 'getError'); throw new Error('Probe must not consume app errors'); }
  finish() { enter(this, 'finish'); throw new Error('Probe must not stall GPU'); }
  flush() { enter(this, 'flush'); throw new Error('Probe must not force submission'); }
  clientWaitSync() { enter(this, 'clientWaitSync'); throw new Error('Probe must not wait for GPU'); }
  advance(turns = 1) { this.turn += turns; }
  lose(notify = true) {
    this.lost = true; this.current = null; this.live.clear();
    if (notify) this.canvas.dispatch('webglcontextlost');
  }
  restore() {
    this.lost = false; this.generation++; this.disjoint = false;
    this.canvas.dispatch('webglcontextrestored');
  }
}
let checks = 0;
function check(label, fn) {
  try { fn(); checks++; }
  catch (error) { console.error(`FAIL: ${label}`); throw error; }
}
function eq(actual, expected, label) { check(label, () => assert.strictEqual(actual, expected)); }
function count(gl, name) { return gl.calls[name] || 0; }
function fixture(options = {}, glOptions = {}) {
  const gl = new FakeGL(glOptions), probe = createProbe(gl, options);
  return { gl, probe };
}
function sample(gl, probe, frame, segment = 'A') {
  const began = probe.beginFrame(frame, segment);
  probe.endFrame();
  gl.advance();
  return began;
}
function noDanger(gl, label) {
  for (const name of ['finish', 'flush', 'getError', 'clientWaitSync']) eq(count(gl, name), 0, `${label}: no ${name}`);
}

check('browser-global script import is inert', () => {
  const browser = {};
  vm.runInNewContext(fs.readFileSync(require.resolve('../engine/experiments/gpu-timer-probe'), 'utf8'), browser);
  assert.equal(typeof browser.GpuTimerProbe.createProbe, 'function');
  assert.deepEqual(Object.keys(browser), ['GpuTimerProbe']);
});
for (const [options, label] of [[{ poolSize: 0 }, 'zero pool'], [{ poolSize: 33 }, 'oversized pool'], [{ sampleEvery: 0 }, 'zero cadence'], [{ maxPoll: 0 }, 'zero poll limit'], [{ maxSamples: Infinity }, 'unbounded samples']]) {
  check(`reject invalid configuration: ${label}`, () => assert.throws(() => createProbe(new FakeGL(), options), RangeError));
}
{
  const probe = createProbe(null);
  eq(probe.snapshot().supported, false, 'missing context is unsupported');
  eq(probe.snapshot().mean_ms, null, 'missing context is not zero milliseconds');
  probe.setEnabled(true); eq(probe.beginFrame(), false, 'missing context cannot begin');
  eq(probe.drain().done, true, 'missing context drains immediately'); probe.dispose();
}
for (const glOptions of [{ extension: false }, { bits: 0 }]) {
  const { gl, probe } = fixture({}, glOptions);
  const snap = probe.snapshot();
  eq(snap.supported, false, 'unsupported capability distinguished');
  eq(snap.status, 'unavailable', 'unsupported status is explicit');
  eq(snap.mean_ms, null, 'unsupported mean is null');
  eq(snap.p95_ms, null, 'unsupported percentile is null');
  probe.setEnabled(true);
  for (let i = 0; i < 20; i++) sample(gl, probe, i);
  eq(count(gl, 'createQuery'), 0, 'unsupported context allocates no queries');
  eq(probe.snapshot().valid_samples, 0, 'unsupported context fabricates no results');
  noDanger(gl, 'unsupported'); probe.dispose();
}
{
  const { gl, probe } = fixture();
  eq(probe.snapshot().status, 'disabled', 'supported probe starts disabled');
  eq(probe.snapshot().supported, true, 'disabled is not unsupported');
  eq(count(gl, 'createQuery'), 0, 'disabled probe allocates no pool');
  const before = { ...gl.calls };
  for (let i = 0; i < 30; i++) sample(gl, probe, i);
  check('disabled frame hooks make no GL calls', () => assert.deepEqual(gl.calls, before));
  eq(probe.snapshot().valid_samples, 0, 'disabled control has zero samples');
  eq(probe.snapshot().mean_ms, null, 'disabled empty mean is null');
  probe.dispose();
}
{
  const { gl, probe } = fixture({ sampleEvery: 1, poolSize: 3 });
  const appState = { ...gl.appState };
  probe.setEnabled(true);
  eq(count(gl, 'createQuery'), 3, 'explicit enable preallocates pool before measured frame');
  eq(probe.beginFrame(19, 'round-A'), true, 'first sampled frame begins');
  eq(count(gl, 'createQuery'), 3, 'first measured frame does not allocate its pool');
  eq(probe.snapshot().active, true, 'active scope is reported');
  eq(probe.beginFrame(20, 'nested'), false, 'nested frame begin skipped');
  eq(probe.endFrame(), true, 'owned scope ends');
  eq(probe.endFrame(), false, 'duplicate end does not end anything');
  probe.setEnabled(false);
  eq(probe.drain().pending, 1, 'same-turn result remains pending');
  eq(count(gl, 'result'), 0, 'same-turn result is never read');
  gl.advance(); probe.drain();
  eq(count(gl, 'result'), 0, 'one browser turn need not make result available');
  gl.advance(); eq(probe.drain().done, true, 'later available result drains');
  const snap = probe.snapshot();
  eq(snap.valid_samples, 1, 'one completed result retained');
  eq(snap.mean_ms, 7.5, 'nanoseconds converted to milliseconds');
  eq(snap.samples[0].frame_id, 19, 'result remains attached to originating frame');
  eq(snap.samples[0].segment_id, 'round-A', 'result retains originating segment');
  eq(snap.allocated_queries, 3, 'fixed pool allocated once');
  const calls = { ...gl.calls }; probe.snapshot();
  check('snapshot makes no native queries', () => assert.deepEqual(gl.calls, calls));
  check('framebuffer/scissor/program state unchanged', () => assert.deepEqual(gl.appState, appState));
  snap.samples[0].elapsed_ms = 999; snap.stats.errors = 999; snap.config.poolSize = 999;
  eq(probe.snapshot().mean_ms, 7.5, 'snapshot mutations cannot corrupt internal samples');
  eq(probe.snapshot().stats.errors, 0, 'snapshot mutations cannot corrupt counters');
  noDanger(gl, 'normal measurement'); probe.dispose();
  eq(gl.live.size, 0, 'dispose deletes all owned live queries');
  eq(gl.canvas.count(), 0, 'dispose removes canvas listeners');
}
{
  const { gl, probe } = fixture({ poolSize: 2, sampleEvery: 4, maxPoll: 1 }, { latency: 1000 });
  probe.setEnabled(true);
  for (let frame = 0; frame < 40; frame++) {
    const before = { ...gl.calls };
    sample(gl, probe, frame);
    if (frame % 4 !== 0) check('unsampled frame hooks make no GL calls', () => assert.deepEqual(gl.calls, before));
  }
  const snap = probe.snapshot();
  eq(snap.stats.begun, 2, 'full pending pool skips new samples');
  eq(snap.stats.skippedSparse, 30, 'sparse cadence respected');
  eq(snap.stats.skippedFull, 8, 'full pool drops work instead of waiting');
  eq(snap.allocated_queries, 2, 'unavailable results cannot grow pool');
  eq(count(gl, 'result'), 0, 'pending queries never cause blocking reads');
  gl.advance(1000);
  let before = count(gl, 'availability');
  eq(probe.drain().pending, 1, 'one drain call obeys maxPoll');
  eq(count(gl, 'availability') - before, 1, 'drain checks no more than maxPoll');
  eq(probe.drain().pending, 0, 'later drain collects remaining result');
  noDanger(gl, 'full pool'); probe.dispose();
}
{
  const { gl, probe } = fixture({ poolSize: 2, sampleEvery: 1 });
  const external = gl.createQuery();
  gl.beginQuery(EXT.TIME_ELAPSED_EXT, external);
  probe.setEnabled(true);
  eq(probe.beginFrame(), false, 'externally owned active timer is skipped');
  eq(probe.endFrame(), false, 'skip does not end externally owned timer');
  eq(gl.current, external, 'external ownership preserved');
  eq(probe.snapshot().stats.skippedExternal, 1, 'external conflict reported');
  gl.endQuery(EXT.TIME_ELAPSED_EXT);
  eq(probe.beginFrame(), true, 'own query begins after external scope ends');
  gl.endQuery(EXT.TIME_ELAPSED_EXT); // Another profiler prematurely ended ours.
  gl.beginQuery(EXT.TIME_ELAPSED_EXT, external);
  const ends = count(gl, 'endQuery');
  eq(probe.endFrame(), false, 'stolen ownership produces no sample');
  eq(count(gl, 'endQuery'), ends, 'probe never ends replacement external scope');
  probe.dispose();
  eq(gl.current, external, 'dispose never ends foreign query');
  eq(gl.live.size, 1, 'dispose never deletes foreign query');
  gl.endQuery(EXT.TIME_ELAPSED_EXT); gl.deleteQuery(external);
}
{
  const { gl, probe } = fixture({ poolSize: 3, sampleEvery: 1 });
  probe.setEnabled(true);
  sample(gl, probe, 1); sample(gl, probe, 2);
  gl.disjoint = true;
  const reads = count(gl, 'result');
  probe.drain();
  eq(count(gl, 'result'), reads, 'disjoint results are discarded before read');
  eq(probe.snapshot().valid_samples, 0, 'disjoint produces no fabricated timing');
  eq(probe.snapshot().pending, 0, 'disjoint invalidates every outstanding query');
  eq(probe.snapshot().stats.discardedDisjoint, 2, 'all disjoint discards counted');
  sample(gl, probe, 3); gl.advance(2); gl.disjointAfterResult = true;
  probe.drain();
  eq(probe.snapshot().valid_samples, 0, 'disjoint during result retrieval cannot publish a sample');
  eq(probe.snapshot().stats.disjointEvents, 2, 'both disjoint epochs reported');
  sample(gl, probe, 4); gl.advance(2); probe.drain();
  eq(probe.snapshot().valid_samples, 1, 'clean later epoch can measure again');
  eq(count(gl, 'createQuery'), 3, 'disjoint handling reuses bounded ended-query pool');
  probe.dispose();
}
{
  const { gl, probe } = fixture({ poolSize: 2, sampleEvery: 1 });
  probe.setEnabled(true); sample(gl, probe, 1);
  probe.beginFrame(2);
  const generation = probe.snapshot().generation;
  gl.lose(false);
  probe.endFrame();
  eq(probe.snapshot().status, 'context_lost', 'pre-event context loss detected');
  eq(probe.snapshot().pending, 0, 'loss invalidates pending old-generation samples');
  eq(probe.snapshot().active, false, 'loss invalidates active scope');
  eq(probe.snapshot().stats.discardedLoss, 2, 'loss discards active and pending');
  gl.canvas.dispatch('webglcontextlost');
  eq(probe.snapshot().stats.contextLosses, 1, 'queued loss event does not count twice');
  gl.restore(); sample(gl, probe, 3, 'restored'); gl.advance(2); probe.drain();
  eq(probe.snapshot().generation, generation + 1, 'restored extension gets fresh generation');
  eq(probe.snapshot().samples[0].segment_id, 'restored', 'only restored-context result retained');
  eq(probe.snapshot().stats.errors, 0, 'old handles are never queried or deleted after restoration');
  eq(count(gl, 'getExtension'), 2, 'extension reacquired after restoration');
  probe.dispose(); eq(gl.live.size, 0, 'restored pool completely disposed');
}
{
  const { gl, probe } = fixture({ poolSize: 3, sampleEvery: 1 });
  gl.nullAllocation = true;
  probe.setEnabled(true);
  eq(probe.snapshot().allocated_queries, 0, 'null allocation does not add a false query handle');
  eq(probe.beginFrame(1), false, 'null allocation skips frame without starting a query');
  eq(probe.snapshot().active, false, 'null allocation cannot leave an active scope');
  eq(probe.snapshot().valid_samples, 0, 'null allocation cannot fabricate a timing');
  eq(probe.snapshot().stats.errors, 0, 'null allocation is handled without a native exception');
  gl.nullAllocation = false;
  sample(gl, probe, 2, 'allocation-recovered'); gl.advance(2); probe.drain();
  eq(probe.snapshot().allocated_queries, 3, 'later frame completes pool after allocation recovers');
  eq(probe.snapshot().valid_samples, 1, 'recovered allocation yields a real completed result');
  probe.dispose(); eq(gl.live.size, 0, 'allocation recovery leaves no leaked handles');
}
{
  const gl = new FakeGL();
  const original = gl.createQuery;
  let allocations = 0;
  gl.createQuery = function () {
    if (++allocations === 2) return null;
    return original.call(this);
  };
  const probe = createProbe(gl, { poolSize: 3, sampleEvery: 1 });
  probe.setEnabled(true);
  eq(probe.snapshot().allocated_queries, 1, 'partially allocated pool retains its first owned handle');
  sample(gl, probe, 1); gl.advance(2); probe.drain();
  eq(probe.snapshot().allocated_queries, 3, 'retry fills only missing pool slots');
  eq(gl.live.size, 3, 'partial retry does not orphan or duplicate earlier allocation');
  probe.dispose(); eq(gl.live.size, 0, 'partial-allocation pool fully disposed');
}
{
  const { gl, probe } = fixture({ poolSize: 2, sampleEvery: 1 });
  probe.setEnabled(true); sample(gl, probe, 1);
  probe.setEnabled(false); probe.reset();
  const beforeLoss = { ...gl.calls };
  gl.lose();
  check('loss event invalidation performs no native GL calls', () => assert.deepEqual(gl.calls, beforeLoss));
  eq(probe.snapshot().status, 'context_lost', 'disabled probe still observes loss event');
  eq(probe.snapshot().allocated_queries, 0, 'loss event clears disabled old-generation pool');
  for (let frame = 0; frame < 12; frame++) sample(gl, probe, frame, 'disabled-lost');
  check('disabled lost frame hooks make no GL calls', () => assert.deepEqual(gl.calls, beforeLoss));
  gl.restore();
  for (let frame = 0; frame < 12; frame++) sample(gl, probe, frame, 'disabled-restored');
  check('disabled restored frame hooks defer capability work', () => assert.deepEqual(gl.calls, beforeLoss));
  eq(probe.snapshot().valid_samples, 0, 'disabled loss/restore cannot add GPU samples');
  probe.setEnabled(true); sample(gl, probe, 100, 'enabled-restored'); gl.advance(2); probe.drain();
  eq(probe.snapshot().valid_samples, 1, 'explicit enable reacquires restored context after disabled loss');
  eq(probe.snapshot().stats.errors, 0, 'disabled loss never reuses invalid old handles');
  probe.dispose(); eq(gl.live.size, 0, 'disabled-loss recovery pool fully disposed');
}
{
  const { gl, probe } = fixture({ poolSize: 2, sampleEvery: 1 });
  probe.setEnabled(true); sample(gl, probe, 1); probe.beginFrame(2);
  eq(probe.reset(), true, 'reset closes owned active timer and drops pending');
  eq(gl.current, null, 'reset leaves no active timer');
  eq(probe.snapshot().last_reset_discarded, 2, 'reset reports discarded previous-window scopes');
  eq(probe.snapshot().valid_samples, 0, 'reset clears previous results');
  for (let window = 0; window < 30; window++) {
    sample(gl, probe, window, `window-${window}`); probe.reset();
    eq(gl.live.size, 2, 'repeated reset neither leaks nor grows query pool');
  }
  eq(count(gl, 'createQuery'), 2, 'reset reuses ended objects rather than allocating per window');
  probe.beginFrame(100); probe.setEnabled(false);
  eq(gl.current, null, 'disable mid-scope ends only owned query');
  eq(probe.snapshot().active, false, 'disable mid-scope discards partial timing');
  eq(probe.snapshot().valid_samples, 0, 'partial disabled scope never becomes valid timing');
  probe.reset();
  for (let frame = 0; frame < 10; frame++) sample(gl, probe, frame, 'control');
  eq(probe.snapshot().stats.begun, 0, 'reset does not inadvertently re-enable control');
  probe.dispose(); probe.dispose(); eq(gl.live.size, 0, 'dispose is idempotent');
  const before = { ...gl.calls }; probe.beginFrame(); probe.endFrame(); probe.reset(); probe.drain();
  check('disposed hooks cannot touch the GL context', () => assert.deepEqual(gl.calls, before));
  const replacement = createProbe(gl); replacement.dispose();
}
{
  const { gl, probe } = fixture({ sampleEvery: 1, maxSamples: 2, poolSize: 2 }, { ns: 2 ** 32 + 123 });
  probe.setEnabled(true);
  for (let frame = 0; frame < 15; frame++) sample(gl, probe, frame);
  gl.advance(3); probe.drain();
  eq(probe.snapshot().valid_samples, 2, 'retained sample memory is bounded');
  eq(probe.snapshot().samples[0].elapsed_ns, 2 ** 32 + 123, '64-bit query result is not truncated to 32 bits');
  eq(probe.snapshot().samples[0].elapsed_ms, (2 ** 32 + 123) / 1e6, 'large elapsed result preserves millisecond conversion');
  check('sample-capacity skips are exposed', () => assert(probe.snapshot().stats.skippedCapacity > 0));
  probe.dispose();
}
for (const ns of [null, NaN, Infinity, -1, 2 ** 64]) {
  const { gl, probe } = fixture({ sampleEvery: 1 }, { ns });
  probe.setEnabled(true); sample(gl, probe, 1); gl.advance(2); probe.drain();
  eq(probe.snapshot().valid_samples, 0, 'invalid elapsed result is not accepted');
  eq(probe.snapshot().mean_ms, null, 'invalid elapsed result is not coerced to zero');
  eq(probe.snapshot().stats.invalidResults, 1, 'invalid elapsed result counted');
  probe.dispose();
}
{
  const { gl, probe } = fixture({ sampleEvery: 1 }, { ns: 0 });
  probe.setEnabled(true); sample(gl, probe, 1); gl.advance(2); probe.drain();
  eq(probe.snapshot().supported, true, 'actual zero result remains distinct from unsupported');
  eq(probe.snapshot().stats.zeroResults, 1, 'actual zero result explicitly diagnosed');
  probe.dispose();
}
{
  const { gl, probe } = fixture({ trackBlits: true, sampleEvery: 1 });
  const other = new FakeGL();
  const getParameters = count(gl, 'getParameter');
  eq(gl.blitFramebuffer(1, 2), 71, 'optional blit hook preserves return value');
  gl.blitFramebuffer.call(other, 3, 4);
  eq(count(gl, 'getParameter'), getParameters, 'blit counter adds no state getters');
  probe.setEnabled(true); probe.beginFrame(1); gl.blitFramebuffer(); gl.blitFramebuffer(); probe.endFrame();
  gl.blitFramebuffer(); gl.advance(2); probe.drain();
  eq(probe.snapshot().stats.blitCalls, 4, 'borrowed-context blits excluded from owner count');
  eq(probe.snapshot().stats.blitsInQuery, 2, 'inside-query blits counted');
  eq(probe.snapshot().stats.blitsOutsideQuery, 2, 'outside-query blits counted');
  eq(probe.snapshot().samples[0].blit_calls, 2, 'sample records enclosed blit calls');
  check('blit wrapper preserves illegal receiver exception', () => assert.throws(() => gl.blitFramebuffer.call({}), TypeError));
  probe.dispose();
  eq(Object.hasOwn(gl, 'blitFramebuffer'), false, 'dispose restores original prototype-method lookup');
  eq(gl.blitFramebuffer, FakeGL.prototype.blitFramebuffer, 'dispose restores native blit implementation');
}
{
  const gl = new FakeGL();
  const nativeBlit = gl.blitFramebuffer;
  Object.defineProperty(gl, 'blitFramebuffer', { value: nativeBlit, writable: true, configurable: true, enumerable: false });
  const before = Object.getOwnPropertyDescriptor(gl, 'blitFramebuffer');
  const probe = createProbe(gl, { trackBlits: true });
  check('second live owner rejected', () => assert.throws(() => createProbe(gl), /already owns/));
  probe.dispose();
  check('own blit property descriptor restored exactly', () => assert.deepEqual(Object.getOwnPropertyDescriptor(gl, 'blitFramebuffer'), before));
  const second = createProbe(gl, { trackBlits: true });
  const newerWrapper = function () { return nativeBlit.apply(this, arguments); };
  gl.blitFramebuffer = newerWrapper;
  second.dispose(); eq(gl.blitFramebuffer, newerWrapper, 'dispose does not overwrite a later owner wrapper');
}
{
  const { gl, probe } = fixture({ sampleEvery: 1 });
  probe.setEnabled(true); gl.failNext = 'beginQuery';
  eq(probe.beginFrame(), false, 'unexpected native exception does not escape into game loop');
  eq(probe.snapshot().enabled, false, 'native exception disables further sampling');
  eq(probe.snapshot().stats.errors, 1, 'native exception is visible in report');
  probe.endFrame(); probe.dispose();
  eq(gl.live.size, 0, 'exception path retains owned resources for cleanup');
}
{
  const { gl, probe } = fixture({ sampleEvery: 1, poolSize: 3, maxPoll: 2, maxSamples: 32 }, { latency: 3 });
  let seed = 0x6f7075;
  const random = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; };
  for (let step = 0; step < 400; step++) {
    switch (random() % 8) {
      case 0: probe.setEnabled((random() & 1) !== 0); break;
      case 1: probe.reset(); break;
      case 2: gl.disjoint = true; break;
      case 3: gl.lose(); gl.restore(); break;
      default: sample(gl, probe, step, 'seeded'); break;
    }
    gl.advance();
    const availability = count(gl, 'availability');
    probe.drain();
    check('seeded drain never exceeds bounded polling', () => assert(count(gl, 'availability') - availability <= 2));
    check('seeded live pool is bounded', () => assert(gl.live.size <= 3));
    check('seeded retained samples are bounded', () => assert(probe.snapshot().valid_samples <= 32));
    eq(probe.snapshot().stats.errors, 0, 'seeded sequence has no invalid native operations');
  }
  probe.dispose(); eq(gl.live.size, 0, 'seeded lifecycle leaves no live owned objects');
  noDanger(gl, 'seeded lifecycle');
}
console.log(`GPU_TIMER_PROBE: ${checks}/${checks} passed; 400 seeded transitions; bounded async fake WebGL2; no browser or GPU work`);
