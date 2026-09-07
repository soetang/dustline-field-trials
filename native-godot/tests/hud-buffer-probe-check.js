'use strict';

// Node-only WebGL forwarding checks: no browser, driver, or rendering context.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const names = ['createBuffer', 'deleteBuffer', 'createVertexArray', 'deleteVertexArray', 'bufferData'];
const counts = Object.fromEntries(names.map(name => [name, 0]));
const calls = [], extraCalls = [];
const originals = {};
let expectedCall;
let checks = 0;

function check(label, fn) {
  try { fn(); checks++; }
  catch (error) { console.error(`FAIL: ${label}`); throw error; }
}
function forbidden(name) {
  return function() {
    extraCalls.push(name);
    throw new Error(`Unexpected driver or rendering call: ${name}`);
  };
}
function FakeGL() {}
for (const name of names) {
  originals[name] = function(...args) {
    calls.push({ name, receiver: this, args });
    assert.equal(expectedCall?.name, name, 'Only the requested native call may run');
    if (expectedCall.throws) throw expectedCall.error;
    return expectedCall.result;
  };
}
for (const name of ['getParameter', 'getError', 'getExtension', 'getQueryParameter',
  'readPixels', 'finish', 'flush', 'clientWaitSync', 'drawArrays', 'drawElements',
  'bindBuffer', 'bindVertexArray', 'bufferSubData']) originals[name] = forbidden(name);
FakeGL.prototype = new Proxy({ ...originals }, {
  get(target, name, receiver) {
    if (!(name in target)) throw new Error(`Unexpected WebGL API access: ${String(name)}`);
    return Reflect.get(target, name, receiver);
  },
});
const first = new FakeGL(); // Existing contexts must also receive the wrappers.
const browser = {
  window: {}, WebGL2RenderingContext: FakeGL,
  requestAnimationFrame: forbidden('requestAnimationFrame'),
  setTimeout: forbidden('setTimeout'),
  document: { createElement: forbidden('createElement') },
};
vm.runInNewContext(fs.readFileSync(require.resolve('./hud-buffer-probe'), 'utf8'), browser,
  { filename: 'hud-buffer-probe.js', timeout: 1000 });
const probe = browser.window.hudBufferProbe;
function readSnapshot() {
  const before = calls.length;
  const result = probe.snapshot();
  assert.equal(calls.length, before, 'Reading a snapshot must not call native methods');
  assert.deepEqual(extraCalls, []);
  return result;
}
const snapshot = () => ({ ...readSnapshot() });

check('installation only exposes the counter API and makes no native calls', () => {
  assert.deepEqual(Object.keys(browser.window), ['hudBufferProbe']);
  assert.deepEqual(Object.keys(probe).sort(), ['reset', 'snapshot']);
  assert.deepEqual(snapshot(), counts);
  assert.equal(calls.length, 0);
  assert.deepEqual(extraCalls, []);
  for (const name of Object.keys(originals).filter(name => !names.includes(name)))
    assert.equal(FakeGL.prototype[name], originals[name], `${name} must remain untouched`);
});

function forward(name, receiver, args, result, error, throws = false) {
  expectedCall = { name, result, error, throws };
  const before = calls.length;
  if (throws) {
    let caught = false;
    try { Reflect.apply(FakeGL.prototype[name], receiver, args); }
    catch (actual) { caught = true; assert.equal(actual, error, 'Exact thrown value must propagate'); }
    assert.ok(caught, 'Native exceptions must not be swallowed');
  } else {
    assert.equal(Reflect.apply(FakeGL.prototype[name], receiver, args), result,
      'Exact native result must propagate');
    counts[name]++;
  }
  assert.equal(calls.length, before + 1, 'Exactly one native call per wrapper call');
  const call = calls[before];
  assert.equal(call.name, name);
  assert.equal(call.receiver, receiver, 'Preserve the original receiver');
  assert.equal(call.args.length, args.length, 'Preserve argument count, including explicit undefined');
  args.forEach((arg, i) => assert.ok(Object.is(call.args[i], arg), `Preserve argument ${i} by identity`));
  assert.deepEqual(snapshot(), counts, 'Count only the invoked method after a normal return');
  assert.deepEqual(extraCalls, []);
  expectedCall = undefined;
}

const second = new FakeGL(), buffer = {}, vao = {}, view = new Uint8Array([9, 8, 7, 6]);
for (const [name, args, result] of [
  ['createBuffer', [], buffer], ['createVertexArray', [], vao],
  ['deleteBuffer', [buffer], undefined], ['deleteVertexArray', [vao], undefined],
  ['bufferData', [0x8892, view, 0x88e8, 1, 2], undefined],
  ['bufferData', [0x8892, view.buffer, 0x88e4], undefined],
  ['bufferData', [0x8892, 4096, 0x88e8], undefined],
  ['createBuffer', [], null], ['deleteBuffer', [null], undefined],
]) check(`${name} preserves native arguments/results across contexts`, () => {
  forward(name, first, args, result);
  forward(name, second, args, result);
});

for (const name of names) {
  check(`${name} preserves unusual receivers, values, and explicit arguments`, () => {
    const args = [buffer, undefined, null, -0, NaN, Symbol('argument')];
    for (const receiver of [{ borrowed: true }, null, undefined])
      forward(name, receiver, args, Symbol('native result'));
  });
  check(`${name} propagates exceptions unchanged without counting a normal return`, () => {
    for (const error of [new TypeError('Illegal receiver'), buffer, undefined])
      forward(name, first, [view], undefined, error, true);
  });
}

check('snapshot mutations cannot change counters or subsequent snapshots', () => {
  const saved = readSnapshot(), independent = readSnapshot();
  assert.notEqual(saved, independent);
  saved.createBuffer = -100;
  delete saved.bufferData;
  saved.extra = 17;
  assert.deepEqual(snapshot(), counts);
  assert.deepEqual({ ...independent }, counts);
  assert.deepEqual([...view], [9, 8, 7, 6], 'Typed array input remains unchanged');
});

check('reset and repeated snapshots make no native calls and preserve saved results', () => {
  const saved = readSnapshot(), before = { ...counts }, nativeCalls = calls.length;
  for (let i = 0; i < 3; i++) {
    probe.reset();
    assert.deepEqual(snapshot(), Object.fromEntries(names.map(name => [name, 0])));
  }
  assert.deepEqual({ ...saved }, before);
  assert.equal(calls.length, nativeCalls);
  assert.deepEqual(extraCalls, []);
  for (const name of names) counts[name] = 0;
});

check('the same wrappers resume counting from zero after reset', () => {
  forward('createBuffer', second, [], buffer);
  forward('bufferData', first, [0x8892, view, 0x88e8], undefined);
  assert.equal(snapshot().deleteBuffer, 0);
});

console.log(`HUD_BUFFER_PROBE: ${checks}/${checks} passed; Node only, no rendering`);
