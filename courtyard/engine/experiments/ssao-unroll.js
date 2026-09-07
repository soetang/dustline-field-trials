'use strict';

// Test-only shaderSource substitution; never loaded by the playable game.
// Only loop control changes. Sample coordinates, their repeated additions,
// texture/normalize/smoothstep calls, precision, and accumulation order remain.
// Enabling affects FUTURE shaderSource calls, not already compiled programs.
// Compare fresh, warmed pages and pixels before making a performance claim.
//
// PINNED_SOURCE is Godot 4.7.2-stable drivers/gles3/shaders/s4ao_inc.glsl:
// https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/gles3/shaders/s4ao_inc.glsl
// S4AO attribution: Jonathan Dummer (O1S).
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
(function (root) {
  const PINNED_SOURCE = `// S4AO (Stupid Simple Screen Space Ambient Occlusion) - Jonathan Dummer (O1S)

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
  const loopStart = PINNED_SOURCE.indexOf('\tfor (int j = sample_width;');
  const loopEnd = PINNED_SOURCE.indexOf('\t// Adjust the occlusion');
  const ORIGINAL_LOOP = PINNED_SOURCE.slice(loopStart, loopEnd);
  const sampleStart = ORIGINAL_LOOP.indexOf('#ifdef USE_MULTIVIEW');
  const sampleEnd = ORIGINAL_LOOP.indexOf('\n\t\t}', sampleStart);
  const SAMPLE_BLOCK = ORIGINAL_LOOP.slice(sampleStart, sampleEnd) + '\n';
  const rowStart = '\t\tvec2 duv = (float(o) - sample_mid) * rcos + base_duv;\n';
  const rowEnd = '\t\tbase_duv += rsin; // March along the rsin direction with j.\n';
  // j descends 3, 2, 1, 0 while base_duv advances by repeated addition.
  // Blocks give each unchanged sample's dz/validity declarations their scope.
  const UNROLLED_LOOP = [1, 0, 0, 1].map((notch, row) =>
    `\t{ // SSAO_UNROLL_ROW j=${3 - row}; samples=${4 - notch - notch}\n` +
    `\t\tconst int o = ${notch};\n` + rowStart +
    Array.from({ length: 4 - notch - notch }, () => '\t\t{\n' + SAMPLE_BLOCK + '\t\t}\n').join('') +
    rowEnd + '\t}\n').join('');
  const REASONS = ['disabled', 'non_string', 'not_medium', 'not_ssao', 'ambiguous_define',
    'conditional_define', 'other_variant', 'source_drift', 'duplicate_source', 'replaced'];
  const installedHooks = new WeakMap();

  function transformSource(source, { enabled = false } = {}) {
    const result = (reason, matched = false, replaced = false, output = source) =>
      ({ source: output, reason, matched, replaced, rejected: matched && !replaced });
    // No coercion: WebIDL must perform native argument conversion exactly once.
    if (enabled !== true) return result('disabled');
    if (typeof source !== 'string') return result('non_string');
    const uncommented = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, text => text.replace(/[^\n]/g, ' '));
    const definitions = [...uncommented.matchAll(/^[\t ]*#[\t ]*(define|undef)[\t ]+(USE_SSAO_(?:MED|LOW|HIGH|MEGA|ABYSS)|USE_MULTIVIEW)\b([^\n]*)/gm)];
    const medium = definitions.filter(match => match[2] === 'USE_SSAO_MED');
    if (!medium.length) return result('not_medium');
    // Godot gives its post vertex shader the same specialization defines.
    // It has no s4ao function and is unrelated, not a rejected fragment match.
    if (!/\bs4ao\s*\(/.test(uncommented)) return result('not_ssao');
    if (medium.length !== 1 || medium[0][1] !== 'define' || medium[0][3].trim() !== '')
      return result('ambiguous_define', true);
    // Godot emits active specialization defines in an unconditional preamble.
    // Do not implement a general GLSL preprocessor or guess nested macro state.
    const preamble = uncommented.slice(0, medium[0].index);
    if (preamble.includes('\\') ||
        preamble.split('\n').some(line => line.trim() && !/^[\t ]*#[\t ]*(?:version|define|extension|line)\b/.test(line)))
      return result('conditional_define', true);
    // GLSL splices escaped newlines before tokenization/comments. A later
    // "USE_SSAO_\\\nHIGH" could otherwise evade the conflicting-define guard.
    // The pinned generated post shader has no continuations; reject rather
    // than introducing a partial preprocessor with different token semantics.
    if (/\\\r?\n/.test(source)) return result('ambiguous_define', true);
    // Even an inactive conflicting define is conservatively unsupported.
    if (definitions.some(match => match[2] !== 'USE_SSAO_MED')) return result('other_variant', true);
    const at = source.indexOf(PINNED_SOURCE);
    if (at < 0) return result('source_drift', true);
    const firstLoop = source.indexOf(ORIGINAL_LOOP);
    if (source.indexOf(PINNED_SOURCE, at + 1) >= 0 ||
        firstLoop < 0 || source.indexOf(ORIGINAL_LOOP, firstLoop + 1) >= 0)
      return result('duplicate_source', true);
    const offset = at + loopStart;
    // An exact snippet inside a block comment is not executable shader code.
    if (uncommented.slice(offset, offset + 5) !== '\tfor ')
      return result('source_drift', true);
    return result('replaced', true, true,
      source.slice(0, offset) + UNROLLED_LOOP + source.slice(offset + ORIGINAL_LOOP.length));
  }

  function installCanvasHook(canvasPrototype, { enabled = false } = {}) {
    if (!canvasPrototype || typeof canvasPrototype.getContext !== 'function')
      throw new TypeError('HTML canvas prototype with getContext is required');
    if (installedHooks.has(canvasPrototype)) return installedHooks.get(canvasPrototype);
    const nativeGetContext = canvasPrototype.getContext;
    const owned = new WeakSet();
    let enabledNow = enabled === true, contexts = 0, stats;
    function resetStats() {
      stats = { source_calls: 0, matched: 0, replaced: 0, rejected: 0,
        passthrough: 0, exceptions: 0, reasons: Object.fromEntries(REASONS.map(reason => [reason, 0])) };
    }
    resetStats();
    function instrument(gl) {
      if (owned.has(gl) || typeof gl.shaderSource !== 'function') return;
      owned.add(gl); contexts++;
      const nativeShaderSource = gl.shaderSource;
      gl.shaderSource = function () {
        // Borrowed methods still invoke the native method with the actual
        // receiver, without transforming/counting another context's source.
        if (this !== gl) return nativeShaderSource.apply(this, arguments);
        stats.source_calls++;
        const transformed = transformSource(arguments[1], { enabled: enabledNow });
        stats.reasons[transformed.reason]++;
        if (transformed.matched) stats.matched++;
        if (transformed.replaced) stats.replaced++;
        else stats.passthrough++;
        if (transformed.rejected) stats.rejected++;
        let args = arguments;
        if (transformed.replaced) {
          args = Array.from(arguments);
          args[1] = transformed.source;
        }
        try { return nativeShaderSource.apply(this, args); }
        catch (error) { stats.exceptions++; throw error; }
      };
    }
    canvasPrototype.getContext = function (type) {
      const gl = nativeGetContext.apply(this, arguments);
      if (gl && type === 'webgl2' && this.id === 'canvas') instrument(gl);
      return gl;
    };
    const controller = {
      setEnabled(value) { enabledNow = value === true; },
      resetStats,
      snapshot() {
        return { enabled: enabledNow, contexts, ...stats, reasons: { ...stats.reasons },
          adds_driver_queries: false,
          scope: 'Future shaderSource submissions only; matched means a Medium s4ao candidate; counts do not prove compilation or speedup' };
      },
    };
    installedHooks.set(canvasPrototype, controller);
    return controller;
  }
  const api = { transformSource, installCanvasHook };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.SsaoUnroll = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
