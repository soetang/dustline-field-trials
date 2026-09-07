'use strict';

// Opt-in fixture instrumentation; this module does not discover a canvas or
// install itself in the game. CommonJS / window.GpuTimerProbe.createProbe(gl).
// TIME_ELAPSED is a GPU timeline interval, NOT GPU busy time or CPU-exclusive
// cost. Its scope is exactly the commands between beginFrame and endFrame.
// https://registry.khronos.org/webgl/extensions/EXT_disjoint_timer_query_webgl2/
// https://registry.khronos.org/webgl/extensions/EXT_disjoint_timer_query/
// https://registry.khronos.org/OpenGL/extensions/EXT/EXT_disjoint_timer_query.txt
(function (root) {
  const instances = new WeakMap();
  const CURRENT_QUERY = 0x8865, RESULT = 0x8866, AVAILABLE = 0x8867;
  function integerOption(options, name, fallback, maximum) {
    const value = options[name] ?? fallback;
    if (!Number.isInteger(value) || value < 1 || value > maximum)
      throw new RangeError(`${name} must be an integer in 1..${maximum}`);
    return value;
  }
  function createProbe(gl, options = {}) {
    const config = {
      poolSize: integerOption(options, 'poolSize', 8, 32),
      sampleEvery: integerOption(options, 'sampleEvery', 4, 240),
      maxPoll: integerOption(options, 'maxPoll', 2, 32),
      maxSamples: integerOption(options, 'maxSamples', 2048, 8192),
      trackBlits: options.trackBlits === true,
    };
    const validObject = gl !== null && (typeof gl === 'object' || typeof gl === 'function');
    if (validObject && instances.has(gl)) throw new Error('A GPU timer probe already owns this context; dispose it first');
    const names = ['getExtension', 'isContextLost', 'getParameter', 'getQuery',
      'createQuery', 'deleteQuery', 'beginQuery', 'endQuery', 'getQueryParameter'];
    const missing = names.filter(name => typeof gl?.[name] !== 'function');
    const native = {};
    for (const name of names) if (!missing.includes(name)) native[name] = gl[name].bind(gl);
    let enabled = false, disposed = false, initialized = false, supported = false, lost = false;
    let reason = missing.length ? `Missing WebGL2 methods: ${missing.join(', ')}` : 'Not initialized';
    let ext = null, bits = 0, generation = 0, frame = 0, active = null;
    let slots = [], free = [], pending = [], samples = [];
    let lastError = null, lastResetDiscarded = 0;
    const newStats = () => ({ frames: 0, begun: 0, ended: 0, polls: 0, availabilityChecks: 0,
      resultReads: 0, disjointChecks: 0, skippedSparse: 0, skippedFull: 0, skippedExternal: 0,
      skippedActive: 0, skippedCapacity: 0, ownershipLost: 0, discarded: 0,
      discardedDisjoint: 0, discardedLoss: 0, discardedCapacity: 0, invalidResults: 0,
      zeroResults: 0, disjointEvents: 0, contextLosses: 0, errors: 0,
      blitCalls: 0, blitsInQuery: 0, blitsOutsideQuery: 0 });
    let stats = newStats();
    const call = (fn, fallback = false) => {
      try { return fn(); }
      catch (error) {
        stats.errors++;
        lastError = String(error?.message || error);
        enabled = false;
        return fallback;
      }
    };
    function contextLost() {
      if (disposed || lost) return;
      const discarded = pending.length + (active ? 1 : 0);
      stats.contextLosses++;
      stats.discardedLoss += discarded;
      stats.discarded += discarded;
      // Loss invalidates the objects and extension. Never use/delete these
      // invalid old-generation handles in the restored context.
      lost = true; initialized = false; supported = false; ext = null; bits = 0;
      reason = 'Context lost';
      slots = []; free = []; pending = []; active = null;
    }
    function contextRestored() {
      if (disposed) return;
      lost = false; initialized = false; supported = false; ext = null; bits = 0;
      reason = 'Context restored; capability must be reacquired';
    }
    function ready() {
      if (disposed || missing.length) return false;
      if (native.isContextLost()) { contextLost(); return false; }
      if (lost) contextRestored(); // Also handle a missed/queued canvas event.
      if (!initialized) {
        ext = native.getExtension('EXT_disjoint_timer_query_webgl2');
        if (!ext) {
          supported = false; reason = 'EXT_disjoint_timer_query_webgl2 unavailable'; initialized = true;
          return false;
        }
        const width = native.getQuery(ext.TIME_ELAPSED_EXT, ext.QUERY_COUNTER_BITS_EXT);
        if (!Number.isInteger(width) || width <= 0 || width > 64) {
          supported = false; reason = 'Elapsed query counter has no usable bits'; initialized = true;
          return false;
        }
        bits = width; supported = true; reason = null; initialized = true; generation++;
      }
      return supported;
    }
    function allocate() {
      // Allocate once per live context; reset/disjoint reuse ended objects.
      while (slots.length < config.poolSize) {
        const query = native.createQuery();
        if (!query) { if (native.isContextLost()) contextLost(); return false; }
        const slot = { query };
        slots.push(slot); free.push(slot);
      }
      return true;
    }
    function release(slot) { free.push(slot); }
    function finishActive(record) {
      if (!active) return false;
      if (!ready()) return false;
      const slot = active;
      // Only sampled frames incur this ownership check. It is necessary if
      // another profiler ends our query and starts its own before post_draw.
      if (native.getQuery(ext.TIME_ELAPSED_EXT, CURRENT_QUERY) !== slot.query) {
        active = null; stats.ownershipLost++; stats.discarded++; release(slot);
        return false;
      }
      native.endQuery(ext.TIME_ELAPSED_EXT);
      active = null; stats.ended++;
      if (record) pending.push(slot);
      else { stats.discarded++; release(slot); }
      return true;
    }
    function discardOutstanding(disjoint = false) {
      const count = pending.length + (active ? 1 : 0);
      finishActive(false);
      stats.discarded += pending.length;
      for (const slot of pending) release(slot);
      pending = [];
      if (disjoint) stats.discardedDisjoint += count;
      return count;
    }
    function cleanDisjoint() {
      stats.disjointChecks++;
      const disjoint = native.getParameter(ext.GPU_DISJOINT_EXT);
      if (disjoint === true) {
        stats.disjointEvents++;
        discardOutstanding(true);
        return false;
      }
      if (disjoint !== false) {
        if (native.isContextLost()) contextLost();
        return false;
      }
      return true;
    }
    function poll() {
      if (!ready() || active) return false;
      stats.polls++;
      if (!cleanDisjoint()) return false;
      const collected = [];
      // No polling loop waits for a result. The fixed bound limits driver calls;
      // unavailable results remain pending until a later browser event turn.
      for (let index = 0; index < pending.length && index < config.maxPoll; index++) {
        const slot = pending[index];
        stats.availabilityChecks++;
        if (native.getQueryParameter(slot.query, AVAILABLE) !== true) break;
        stats.resultReads++;
        collected.push({ slot, elapsed: native.getQueryParameter(slot.query, RESULT) });
      }
      // Do not publish results if a disjoint happened during collection.
      if (collected.length && !cleanDisjoint()) return false;
      for (const { slot, elapsed } of collected) {
        pending.shift();
        if (typeof elapsed !== 'number' || !Number.isFinite(elapsed) || elapsed < 0 || elapsed >= 2 ** bits) {
          stats.invalidResults++;
        } else if (samples.length >= config.maxSamples) {
          stats.discardedCapacity++;
        } else {
          if (elapsed === 0) stats.zeroResults++;
          samples.push({ frame_id: slot.frameId, segment_id: slot.segmentId, generation: slot.generation,
            elapsed_ns: elapsed, elapsed_ms: elapsed / 1e6, latency_frames: frame - slot.frame,
            blit_calls: slot.blitCalls });
        }
        release(slot);
      }
      return true;
    }
    function snapshot() {
      const values = samples.map(sample => sample.elapsed_ms).sort((a, b) => a - b);
      const percentile = p => values.length ? values[Math.ceil(values.length * p) - 1] : null;
      return {
        enabled, supported, status: disposed ? 'disposed' : lost ? 'context_lost' : !supported ? 'unavailable' : enabled ? 'enabled' : 'disabled',
        unavailable_reason: reason, last_error: lastError, generation, counter_bits: bits,
        scope: 'GPU timeline interval between beginFrame/endFrame; not GPU busy time; excludes commands outside hooks and browser composition/scanout',
        config: { ...config }, valid_samples: samples.length, pending: pending.length,
        active: active !== null, allocated_queries: slots.length, last_reset_discarded: lastResetDiscarded,
        mean_ms: values.length ? values.reduce((a, b) => a + b, 0) / values.length : null,
        p50_ms: percentile(0.5), p95_ms: percentile(0.95), p99_ms: percentile(0.99),
        stats: { ...stats }, samples: samples.map(sample => ({ ...sample })),
        blit_counter_scope: 'All owned-context blitFramebuffer calls, not specifically presentation or successful draws',
      };
    }
    const oldBlitDescriptor = validObject ? Object.getOwnPropertyDescriptor(gl, 'blitFramebuffer') : undefined;
    const originalBlit = gl?.blitFramebuffer;
    let blitWrapper = null;
    if (config.trackBlits && typeof originalBlit === 'function') {
      blitWrapper = function () {
        const result = originalBlit.apply(this, arguments);
        if (this === gl && !disposed) {
          stats.blitCalls++;
          if (active) { stats.blitsInQuery++; active.blitCalls++; }
          else stats.blitsOutsideQuery++;
        }
        return result;
      };
      gl.blitFramebuffer = blitWrapper;
    }
    gl?.canvas?.addEventListener('webglcontextlost', contextLost);
    gl?.canvas?.addEventListener('webglcontextrestored', contextRestored);
    const controller = {
      setEnabled(value) {
        if (disposed) return false;
        enabled = Boolean(value);
        // Fixtures enable before starting their wall timer. Keep one-time pool
        // allocation out of the first measured frame; beginFrame only retries
        // after an incomplete allocation or restored context.
        if (enabled) call(() => { if (ready()) allocate(); });
        else call(() => finishActive(false));
        return enabled;
      },
      beginFrame(frameId, segmentId = null) {
        if (disposed) return false;
        frame++;
        if (!enabled) return false;
        stats.frames++;
        if (active) { stats.skippedActive++; return false; }
        if ((stats.frames - 1) % config.sampleEvery !== 0) { stats.skippedSparse++; return false; }
        return call(() => {
          if (!poll()) return false;
          if (samples.length >= config.maxSamples) { stats.skippedCapacity++; return false; }
          if (native.getQuery(ext.TIME_ELAPSED_EXT, CURRENT_QUERY) !== null) { stats.skippedExternal++; return false; }
          if (!allocate() || !free.length) { stats.skippedFull++; return false; }
          active = free.pop();
          Object.assign(active, { frameId: frameId ?? frame, segmentId, frame, generation, blitCalls: 0 });
          native.beginQuery(ext.TIME_ELAPSED_EXT, active.query);
          stats.begun++;
          return true;
        });
      },
      endFrame() { return disposed ? false : call(() => finishActive(true)); },
      reset() {
        if (disposed) return false;
        return call(() => {
          lastResetDiscarded = discardOutstanding();
          stats = newStats(); samples = []; frame = 0; lastError = null;
          return true;
        });
      },
      drain() {
        if (!disposed && (pending.length || active)) call(poll);
        return { pending: pending.length, active: active !== null, done: !pending.length && !active };
      },
      snapshot,
      dispose() {
        if (disposed) return;
        enabled = false;
        call(() => {
          if (!missing.length && !native.isContextLost()) {
            finishActive(false);
            for (const slot of slots) native.deleteQuery(slot.query);
          }
        });
        slots = []; free = []; pending = []; active = null; disposed = true;
        gl?.canvas?.removeEventListener('webglcontextlost', contextLost);
        gl?.canvas?.removeEventListener('webglcontextrestored', contextRestored);
        if (blitWrapper && gl.blitFramebuffer === blitWrapper) {
          if (oldBlitDescriptor) Object.defineProperty(gl, 'blitFramebuffer', oldBlitDescriptor);
          else delete gl.blitFramebuffer;
        }
        if (validObject) instances.delete(gl);
      },
    };
    if (validObject) instances.set(gl, controller);
    call(ready);
    return controller;
  }
  const api = { createProbe };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.GpuTimerProbe = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
