'use strict';

// Fast Node-only correctness tests. Never creates a real GL context, launches
// Godot, downloads source, or compiles shaders. Pixel/GPU checks are separate.
// The independent GLSL fixture below is copied from Godot 4.7.2-stable:
// drivers/gles3/shaders/s4ao_inc.glsl; S4AO by Jonathan Dummer (O1S).
// Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
// Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { transformSource, installCanvasHook } = require('../engine/experiments/ssao-unroll.js');
let checks = 0;
function equal(actual, expected, label) { assert.deepEqual(actual, expected, label); checks++; }
function ok(value, label) { assert.ok(value, label); checks++; }
function throwsSame(fn, error, label) { assert.throws(fn, thrown => thrown === error, label); checks++; }
function throws(fn, label) { assert.throws(fn, undefined, label); checks++; }

const FIXTURE = `// S4AO (Stupid Simple Screen Space Ambient Occlusion) - Jonathan Dummer (O1S)

// The sample_width should be even, else the midpoint is at UV.
// Takes sample_width^2 samples in a grid, with the corners notched.
#if defined(USE_SSAO_LOW)
const int sample_width = 2;
#elif defined(USE_SSAO_HIGH)
const int sample_width = 6;
#else
const int sample_width = 4;
#endif
const int notch_01 = int(sample_width > 3); // Set to 1 to skip the corner samples, 0 to include them.
const float sample_mid = (float(sample_width) - 1.0) * 0.50001; // Can't be exactly 0.5 in case sample_width is odd.
#if defined(USE_SSAO_LOW)
const float inv_half_width = 1.0 / sample_mid; // The 2x2 sampling looks wider as all samples are at radius.
#else
const float inv_half_width = 1.7 / sample_mid; // Bake in the 1.7 scale for the random rotation.
#endif
const float average_samples = 1.0 / float(sample_width * sample_width - 4 * notch_01); //  1 / number_of_samples
const float ssao_falloff_frac = 0.25;
// Perform the SSAO.
float s4ao(vec2 UV) {
#ifdef USE_MULTIVIEW
	float depth = texture(depth_buffer_array, vec3(UV, view)).r;
#else
	float depth = texture(depth_buffer, UV).r;
#endif
	float radius = max(1e-4f, depth * ssao_radius_frac);
	float inv_falloff = 1.0f / max(1e-4f, depth * ssao_falloff_frac);
	// Random 2D rotation per pixel (+/-45 deg, with 0 having a lower probability).
	// The random cosine vector is vec2( 0.5, -0.5 to +0.5 ) and *1.7 makes the average length ~ 1.
	vec2 rcos = (inv_half_width * radius) * vec2(0.5f, fract(dot(UV, ssao_prn_UV)) - 0.5f);
	vec2 rsin = rcos.yx * vec2(-1, 1); // Perpendicular to the random cosine vector.
	// Grab the samples and determine the occlusion.
	float occlusion = 0.0f;
	vec2 base_duv = -sample_mid * rsin;
	for (int j = sample_width; --j >= 0;) {
#if defined(USE_SSAO_LOW)
		// Low quality uses 2x2 samples, no notching.
		vec2 duv = -sample_mid * rcos + base_duv;
		for (int i = sample_width; --i >= 0;) {
#else
		//	Will uses 4x4 or 6x6 samples, with the corners notched out.
		int o = /*notch_01 &*/ int((j <= 0) || (j >= (sample_width - 1))); // Notch corners of the grid.
		vec2 duv = (float(o) - sample_mid) * rcos + base_duv;
		for (int i = sample_width - o - o; --i >= 0;) {
#endif
#ifdef USE_MULTIVIEW
			float dz = texture(depth_buffer_array, vec3(UV + duv, view)).r - depth;
#else
			float dz = texture(depth_buffer, UV + duv).r - depth;
#endif
			float validity = smoothstep(1.0f, 0.0f, dz * inv_falloff);
			occlusion += normalize(vec3(duv, dz)).z * validity; // How 'directly overhead' is it?
			duv += rcos; // March along the rcos direction with i.
		}
		base_duv += rsin; // March along the rsin direction with j.
	}
	// Adjust the occlusion for intensity, and # samples.
	occlusion *= ssao_intensity * average_samples;
	occlusion = clamp(1.0f - occlusion, 0.0f, 1.0f);
	return occlusion * occlusion;
}
`;
const HEADER = '#version 300 es\n#define USE_SSAO_MED\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n';
const FOOTER = '\nvoid main() { frag_color = vec4(s4ao(vec2(0.5))); }\n';
const source = HEADER + FIXTURE + FOOTER;
const transformed = transformSource(source, { enabled: true });
equal(Object.keys(transformed).sort(), ['matched', 'reason', 'rejected', 'replaced', 'source']);
equal([transformed.matched, transformed.replaced, transformed.rejected, transformed.reason], [true, true, false, 'replaced']);
equal(transformSource(source).source, source, 'Pure transform defaults off');
equal(transformSource(source).reason, 'disabled');
equal(transformSource(source, { enabled: 1 }).source, source, 'Only explicit true enables');

const loopStart = source.indexOf('\tfor (int j = sample_width;');
const loopEnd = source.indexOf('\t// Adjust the occlusion');
const originalLoop = source.slice(loopStart, loopEnd);
const tail = source.slice(loopEnd);
equal(transformed.source.slice(0, loopStart), source.slice(0, loopStart), 'Everything before loop is byte-identical');
equal(transformed.source.slice(-tail.length), tail, 'Everything after loop is byte-identical');
const outputLoop = transformed.source.slice(loopStart, -tail.length);
ok(!/\bfor\s*\(/.test(outputLoop), 'Both loops removed');
ok(!/inversesqrt|textureLod|texelFetch|mediump/.test(outputLoop), 'No altered arithmetic, lookup kind or precision');
const sampleStart = originalLoop.indexOf('#ifdef USE_MULTIVIEW');
const sampleBlock = originalLoop.slice(sampleStart, originalLoop.indexOf('\n\t\t}', sampleStart)) + '\n';
const sampleCalls = outputLoop.match(/#ifdef USE_MULTIVIEW[\s\S]*?duv \+= rcos;[^\n]*\n/g);
equal(sampleCalls, Array(12).fill(sampleBlock), 'All twelve complete sample bodies remain verbatim and ordered');
equal((outputLoop.match(/float dz = texture\(depth_buffer, UV \+ duv\)/g) || []).length, 12, 'Twelve mono depth neighbors');
equal((transformed.source.match(/float depth = texture\(depth_buffer, UV\)/g) || []).length, 1, 'Center fetch remains singular');
equal((outputLoop.match(/base_duv \+= rsin;/g) || []).length, 4, 'Four unchanged row-advance additions');
equal((outputLoop.match(/vec2 duv = \(float\(o\) - sample_mid\) \* rcos \+ base_duv;/g) || []).length, 4, 'Row origin expression unchanged');
const rows = [...outputLoop.matchAll(/SSAO_UNROLL_ROW j=(\d); samples=(\d)\n\t\tconst int o = (\d);/g)]
  .map(match => ({ j: +match[1], samples: +match[2], notch: +match[3] }));
equal(rows, [{ j: 3, samples: 2, notch: 1 }, { j: 2, samples: 4, notch: 0 },
  { j: 1, samples: 4, notch: 0 }, { j: 0, samples: 2, notch: 1 }]);
let expectedLoop = '';
for (let j = 4; --j >= 0;) {
  const o = Number(j <= 0 || j >= 3);
  expectedLoop += `\t{ // SSAO_UNROLL_ROW j=${j}; samples=${4 - o - o}\n\t\tconst int o = ${o};\n`;
  expectedLoop += '\t\tvec2 duv = (float(o) - sample_mid) * rcos + base_duv;\n';
  for (let i = 4 - o - o; --i >= 0;) expectedLoop += '\t\t{\n' + sampleBlock + '\t\t}\n';
  expectedLoop += '\t\tbase_duv += rsin; // March along the rsin direction with j.\n\t}\n';
}
equal(outputLoop, expectedLoop, 'Exact loop replay: no extra statements or reordered row/sample operations');

function unchanged(input, reason, rejected = false) {
  const actual = transformSource(input, { enabled: true });
  equal(actual.source, input, `Passes original source/reference through: ${reason}`);
  equal([actual.reason, actual.replaced, actual.rejected], [reason, false, rejected]);
}
unchanged('', 'not_medium');
unchanged(undefined, 'non_string');
unchanged(null, 'non_string');
unchanged(42, 'non_string');
const noCoercion = { toString() { throw new Error('Pure transform must not coerce'); } };
unchanged(noCoercion, 'non_string');
unchanged(FIXTURE, 'not_medium');
unchanged(HEADER + 'void main() { gl_Position = vec4(0.0); }', 'not_ssao');
unchanged(source.replace('#define USE_SSAO_MED', '// #define USE_SSAO_MED'), 'not_medium');
unchanged(source.replace('#define USE_SSAO_MED', '/*\n#define USE_SSAO_MED\n*/'), 'not_medium');
unchanged(source.replace('#define USE_SSAO_MED', '#if 0\n#define USE_SSAO_MED\n#endif'), 'conditional_define', true);
unchanged(source.replace('#define USE_SSAO_MED', '#ifdef UNKNOWN\n#define USE_SSAO_MED\n#endif'), 'conditional_define', true);
unchanged(source.replace('#define USE_SSAO_MED', '#if 0\n#else\n#define USE_SSAO_MED\n#endif'), 'conditional_define', true);
unchanged('precision highp float;\n' + source, 'conditional_define', true);
unchanged(source.replace('#define USE_SSAO_MED', '#define CONTINUED \\\n#define USE_SSAO_MED'), 'conditional_define', true);
unchanged(source.replace('#define USE_SSAO_MED', '#define USE_SSAO_MED\n#define USE_SSAO_\\\nHIGH'), 'ambiguous_define', true);
unchanged(HEADER + '/*\n' + FIXTURE + '\n*/' + FOOTER, 'source_drift', true);
for (const suffix of ['\n#define USE_SSAO_MED', '\n#undef USE_SSAO_MED', ' 0', ' 1', '(x)'])
  unchanged(source.replace('#define USE_SSAO_MED', '#define USE_SSAO_MED' + suffix), 'ambiguous_define', true);
for (const name of ['USE_SSAO_LOW', 'USE_SSAO_HIGH', 'USE_SSAO_MEGA', 'USE_SSAO_ABYSS', 'USE_MULTIVIEW']) {
  unchanged(source.replace('USE_SSAO_MED\n', name + '\n'), 'not_medium');
  unchanged(source.replace('#define USE_SSAO_MED', '#define USE_SSAO_MED\n#define ' + name), 'other_variant', true);
}
unchanged(source.replace('#define USE_SSAO_MED', '#define USE_SSAO_MED\n#if 0\n#define USE_SSAO_LOW\n#endif'), 'other_variant', true);
ok(transformSource(source.replace('#define USE_SSAO_MED', '#define USE_GLOW\n#define USE_SSAO_MED // active'), { enabled: true }).replaced,
  'Unrelated Godot specialization and trailing comment are supported');
for (const [before, after] of [['0.50001', '0.5'], ['const int sample_width = 4;', 'const int sample_width = 5;'],
  ['occlusion += normalize', 'occlusion +=  normalize'], ['duv += rcos;', 'duv = duv + rcos;'],
  ['smoothstep(1.0f, 0.0f', 'smoothstep(0.0f, 1.0f'], ['ssao_falloff_frac = 0.25;', 'ssao_falloff_frac = 0.26;'],
  ['radius = max(1e-4f', 'radius = max(1e-3f'], ['// How', '// HOW']])
  unchanged(source.replace(before, after), 'source_drift', true);
unchanged(source.replaceAll('\n', '\r\n'), 'source_drift', true);
unchanged(source + FIXTURE, 'duplicate_source', true);
unchanged(source + originalLoop, 'duplicate_source', true);
unchanged(transformed.source, 'source_drift', true);

// Float32 coordinate transcript: original loop bounds vs rows decoded from
// actual replacement, including every ordered addition and final row state.
// This validates control-flow equivalence, not GPU normalize/texture behavior.
const f = Math.fround, mid = f(f(4 - 1) * f(0.50001));
let seed = 0x4a0472;
function random() { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; }
function transcript(rcos, rsin, inputRows) {
  let base = rsin.map(v => f(-mid * v));
  const samples = [];
  for (const row of inputRows) {
    let duv = rcos.map((v, axis) => f(f(f(row.notch - mid) * v) + base[axis]));
    for (let i = row.samples; --i >= 0;) {
      samples.push([row.j, ...duv]);
      duv = duv.map((v, axis) => f(v + rcos[axis]));
    }
    base = base.map((v, axis) => f(v + rsin[axis]));
  }
  return { samples, base };
}
const referenceRows = [];
for (let j = 4; --j >= 0;) { const o = Number(j <= 0 || j >= 3); referenceRows.push({ j, notch: o, samples: 4 - o - o }); }
for (let trial = 0; trial < 512; trial++) {
  const radius = f(Math.max(1e-4, random() * 0.65));
  const rcos = [f(radius * 0.5), f(radius * (random() - 0.5))];
  const rsin = [f(-rcos[1]), rcos[0]];
  equal(transcript(rcos, rsin, rows), transcript(rcos, rsin, referenceRows), `Float32 sample transcript ${trial}`);
}

function fakeEnvironment() {
  const receiverError = new TypeError('Illegal receiver');
  class FakeGL {
    constructor() { this.calls = []; this.result = {}; this.failure = null; this.coercions = []; }
    shaderSource(shader, text) {
      if (!(this instanceof FakeGL)) throw receiverError;
      this.calls.push({ receiver: this, args: Array.from(arguments) });
      if (this.failure) throw this.failure;
      if (arguments.length < 2) throw receiverError;
      this.coercions.push(String(text));
      return this.result;
    }
    getParameter() { throw new Error('No driver query allowed'); }
    getError() { throw new Error('No GL errors may be consumed'); }
    getShaderParameter() { throw new Error('No shader query allowed'); }
  }
  class Canvas {
    constructor(id = 'canvas', gl = new FakeGL()) { this.id = id; this.gl = gl; this.calls = []; this.failure = null; }
    getContext(type) {
      if (!(this instanceof Canvas)) throw receiverError;
      this.calls.push({ receiver: this, args: Array.from(arguments) });
      if (this.failure) throw this.failure;
      return ['webgl2', 'webgl', '2d'].includes(String(type)) ? this.gl : null;
    }
  }
  return { FakeGL, Canvas, receiverError };
}
const { FakeGL, Canvas, receiverError } = fakeEnvironment();
const controller = installCanvasHook(Canvas.prototype);
equal(installCanvasHook(Canvas.prototype, { enabled: true }), controller, 'Installation is idempotent without changing enabled state');
equal(controller.snapshot().enabled, false);
const canvas = new Canvas(), options = { antialias: false }, extra = {};
const gl = canvas.getContext('webgl2', options, extra), shader = {};
equal(gl, canvas.gl);
equal(canvas.calls[0].args, ['webgl2', options, extra], 'getContext receives original arity/argument identities');
equal(canvas.calls[0].receiver, canvas);
const wrapper = gl.shaderSource;
equal(canvas.getContext('webgl2'), gl);
equal(gl.shaderSource, wrapper, 'Repeated getContext never wraps twice');
equal(controller.snapshot().contexts, 1);
equal(gl.shaderSource(shader, source, extra), gl.result, 'Native return identity preserved while disabled');
equal(gl.calls.at(-1).args, [shader, source, extra]);
equal(controller.snapshot().reasons.disabled, 1);
equal(controller.snapshot().replaced, 0);
controller.setEnabled(1);
equal(controller.snapshot().enabled, false, 'No truthy accidental enable');
controller.setEnabled(true);
equal(gl.shaderSource(shader, source, extra), gl.result, 'Native return identity preserved while enabled');
equal(gl.calls.at(-1).args, [shader, transformed.source, extra], 'Only the source argument changes');
equal(gl.calls.at(-1).receiver, gl);
equal(controller.snapshot().replaced, 1);
equal(controller.snapshot().matched, 1);
equal(controller.snapshot().adds_driver_queries, false);
gl.shaderSource(shader, source.replace('0.50001', '0.5'));
equal(controller.snapshot().rejected, 1);
equal(gl.calls.at(-1).args[1], source.replace('0.50001', '0.5'));
gl.shaderSource(shader, 'other shader');
equal(gl.calls.at(-1).args[1], 'other shader');
let conversions = 0;
const coercedSource = { toString() { conversions++; return source; } };
gl.shaderSource(shader, coercedSource);
equal(conversions, 1, 'Source objects are coerced only by native WebIDL path');
equal(gl.calls.at(-1).args[1], coercedSource);
equal(gl.coercions.at(-1), source, 'Coerced strings are never transformed indirectly');
const nativeError = new Error('Native shaderSource failure');
gl.failure = nativeError;
throwsSame(() => gl.shaderSource(shader, source, extra), nativeError, 'Native exception identity preserved');
equal(gl.calls.at(-1).args, [shader, transformed.source, extra]);
gl.failure = null;
equal(controller.snapshot().exceptions, 1);
throwsSame(() => gl.shaderSource(), receiverError, 'Missing native arguments are not filled in');
equal(gl.calls.at(-1).args, []);

const foreign = new FakeGL();
const beforeBorrow = controller.snapshot();
equal(wrapper.call(foreign, shader, source, extra), foreign.result);
equal(foreign.calls.at(-1).args, [shader, source, extra], 'Borrowed receiver source untouched');
equal(controller.snapshot(), beforeBorrow, 'Borrowed context uncounted');
throwsSame(() => wrapper.call({}, shader, source), receiverError, 'Illegal borrowed receiver reaches native check');
equal(controller.snapshot(), beforeBorrow);
const canvas2 = new Canvas(), gl2 = canvas2.getContext('webgl2');
equal(controller.snapshot().contexts, 2);
const beforeOwnedBorrow = controller.snapshot();
wrapper.call(gl2, shader, source);
equal(gl2.calls.at(-1).args[1], source, 'Borrowing between owned contexts also remains native');
equal(controller.snapshot(), beforeOwnedBorrow);
gl2.shaderSource(shader, source);
equal(gl2.calls.at(-1).args[1], transformed.source, 'Second owned context own method is instrumented');
for (const [id, type] of [['other', 'webgl2'], ['canvas', 'webgl'], ['canvas', '2d']]) {
  const otherCanvas = new Canvas(id), native = otherCanvas.gl.shaderSource;
  equal(otherCanvas.getContext(type).shaderSource, native, `Unowned context untouched: ${id}/${type}`);
  otherCanvas.gl.shaderSource(shader, source);
  equal(otherCanvas.gl.calls.at(-1).args[1], source);
}
const coercibleCanvas = new Canvas();
let contextConversions = 0;
const contextType = { toString() { contextConversions++; return 'webgl2'; } };
const nativeCoercible = coercibleCanvas.gl.shaderSource;
equal(coercibleCanvas.getContext(contextType).shaderSource, nativeCoercible, 'No extra context-type coercion');
equal(contextConversions, 1);
equal(canvas.getContext('unsupported'), null);
equal(new Canvas('canvas', {}).getContext('webgl2'), {}, 'Missing shaderSource is passed through');
const contextError = new Error('Native getContext failure');
canvas.failure = contextError;
throwsSame(() => canvas.getContext('webgl2', options), contextError);
throwsSame(() => Canvas.prototype.getContext.call({}, 'webgl2'), receiverError);
const snapshot = controller.snapshot();
snapshot.reasons.replaced = -100;
snapshot.replaced = -100;
ok(controller.snapshot().replaced > 0 && controller.snapshot().reasons.replaced > 0, 'Snapshots have no mutable stats aliases');
controller.resetStats();
equal(controller.snapshot().contexts, 2, 'Reset retains context instrumentation');
equal(controller.snapshot().enabled, true, 'Reset retains enabled state');
equal(controller.snapshot().source_calls, 0);
equal(Object.values(controller.snapshot().reasons), Array(10).fill(0));
controller.setEnabled(false);
gl.shaderSource(shader, source);
equal(gl.calls.at(-1).args[1], source, 'Disabling restores pass-through for future submissions');
equal(controller.snapshot().replaced, 0);
equal(controller.snapshot().reasons.disabled, 1);
for (const value of [null, undefined, {}, { getContext: 7 }]) throws(() => installCanvasHook(value), 'Invalid installer target');

const browser = {};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../engine/experiments/ssao-unroll.js'), 'utf8'), browser);
equal(Object.keys(browser.SsaoUnroll).sort(), ['installCanvasHook', 'transformSource']);
equal(browser.SsaoUnroll.transformSource(source, { enabled: true }).source, transformed.source, 'Browser-global/CommonJS transforms agree');
equal(browser.SsaoUnroll.transformSource(source).source, source, 'Browser load does not enable or require a canvas');

// Optional direct check against the locally unpacked pin. No download/build.
const engine = path.resolve(__dirname, '../../.tools/engine-lab/godot-4.7.2-stable');
const pinnedFile = path.join(engine, 'drivers/gles3/shaders/s4ao_inc.glsl');
if (fs.existsSync(pinnedFile)) {
  equal(fs.readFileSync(pinnedFile, 'utf8'), FIXTURE, 'Independent fixture equals actual pinned upstream file');
  const headerFile = path.join(engine, 'drivers/gles3/shaders/effects/post.glsl.gen.h');
  if (fs.existsSync(headerFile)) {
    // Godot splits long C++ raw string literals; adjacent literals concatenate
    // without adding/removing shader characters when the engine is compiled.
    const generated = fs.readFileSync(headerFile, 'utf8').replaceAll(')<!>" R"<!>(', '');
    ok(generated.includes(FIXTURE), 'Generated engine shader retains the exact pinned snippet');
    for (const stage of ['vertex', 'fragment']) {
      const declaration = generated.indexOf(`static const char _${stage}_code[]`);
      const start = generated.indexOf('R"<!>(', declaration) + 6;
      const shader = generated.slice(start, generated.indexOf(')<!>"', start));
      const actual = transformSource(HEADER + shader, { enabled: true });
      equal([actual.replaced, actual.rejected, actual.reason], stage === 'fragment'
        ? [true, false, 'replaced'] : [false, false, 'not_ssao'], `Actual generated post ${stage} classification`);
    }
  }
} else console.log('Optional upstream-source cross-check skipped: local Godot source absent.');
console.log(`SSAO unroll: ${checks}/${checks} checks passed; 12 unchanged sample blocks; 512 Float32 coordinate transcripts; no real GL/build.`);
