'use strict';

// Isolated lifecycle-fixture audit. Loaded before Engine creates canvas#canvas.
// Counts calls already made by that owned context: no extra driver queries,
// no getError consumption, and no changes to arguments/results/exceptions.
// These counts cover ALL framebuffers in that context, not just backbuffer3d.
(function (root) {
  const COMPLETE = 0x8cd5;
  const METHODS = ['checkFramebufferStatus', 'createFramebuffer', 'deleteFramebuffer',
    'createTexture', 'deleteTexture', 'texImage2D', 'texImage3D', 'texStorage2D',
    'texStorage3D', 'copyTexImage2D', 'renderbufferStorage', 'renderbufferStorageMultisample',
    'framebufferTexture2D', 'framebufferTextureLayer', 'framebufferRenderbuffer', 'blitFramebuffer'];
  const TEXTURE_ALLOCATIONS = new Set(['texImage2D', 'texImage3D', 'texStorage2D', 'texStorage3D', 'copyTexImage2D']);
  const ATTACHMENTS = new Set(['framebufferTexture2D', 'framebufferTextureLayer', 'framebufferRenderbuffer']);
  const DEPTH_FORMATS = new Set([0x1902, 0x84f9, 0x81a5, 0x81a6, 0x81a7, 0x88f0, 0x8cac, 0x8cad]);
  function installCanvasHook(canvasPrototype, canvasId = 'canvas') {
    if (!canvasPrototype || typeof canvasPrototype.getContext !== 'function')
      throw new TypeError('HTML canvas prototype with getContext is required');
    const originalGetContext = canvasPrototype.getContext;
    const installed = new WeakSet();
    let contexts = 0, calls, totals, incomplete, incompleteOverflow, multisampleSamples;
    function reset() {
      calls = Object.fromEntries(METHODS.map(name => [name, 0]));
      totals = { checks: 0, complete: 0, incomplete: 0, exceptions: 0,
        texture_allocations: 0, color_texture_allocations: 0, depth_texture_allocations: 0,
        unknown_texture_allocations: 0, renderbuffer_allocations: 0,
        attachments: 0, color_attachments: 0, depth_attachments: 0, stencil_attachments: 0,
        blits: 0, color_blits: 0, depth_blits: 0, stencil_blits: 0 };
      incomplete = []; incompleteOverflow = 0;
      multisampleSamples = { '0': 0, '1': 0, '2': 0, '4': 0, '8': 0, other: 0 };
    }
    reset();
    function record(name, args, result) {
      if (name === 'checkFramebufferStatus') {
        totals.checks++;
        if (result === COMPLETE) totals.complete++;
        else {
          totals.incomplete++;
          // Unknown/invalid values remain visible, but never coerce arbitrary
          // input objects a second time or retain unbounded object references.
          const target = typeof args[0] === 'number' ? args[0] : null;
          const status = typeof result === 'number' ? result : null;
          const previous = incomplete.find(item => item.target === target && item.status === status);
          if (previous) previous.count++;
          else if (incomplete.length < 16) incomplete.push({ target, status, count: 1 });
          else incompleteOverflow++;
        }
      } else if (TEXTURE_ALLOCATIONS.has(name)) {
        totals.texture_allocations++;
        const format = args[2];
        if (DEPTH_FORMATS.has(format)) totals.depth_texture_allocations++;
        else if (typeof format === 'number') totals.color_texture_allocations++;
        else totals.unknown_texture_allocations++;
      } else if (name === 'renderbufferStorage' || name === 'renderbufferStorageMultisample') {
        totals.renderbuffer_allocations++;
        if (name === 'renderbufferStorageMultisample') {
          const samples = args[1];
          const key = [0, 1, 2, 4, 8].includes(samples) ? String(samples) : 'other';
          multisampleSamples[key]++;
        }
      } else if (ATTACHMENTS.has(name)) {
        totals.attachments++;
        const attachment = args[1];
        if (typeof attachment === 'number' && attachment >= 0x8ce0 && attachment <= 0x8cef) totals.color_attachments++;
        if (attachment === 0x8d00 || attachment === 0x821a) totals.depth_attachments++;
        if (attachment === 0x8d20 || attachment === 0x821a) totals.stencil_attachments++;
      } else if (name === 'blitFramebuffer') {
        totals.blits++;
        const mask = args[8];
        if (typeof mask === 'number') {
          if (mask & 0x4000) totals.color_blits++;
          if (mask & 0x0100) totals.depth_blits++;
          if (mask & 0x0400) totals.stencil_blits++;
        }
      }
    }
    function instrument(gl) {
      if (installed.has(gl)) return;
      installed.add(gl); contexts++;
      for (const name of METHODS) {
        const original = gl[name];
        if (typeof original !== 'function') continue;
        gl[name] = function () {
          if (this !== gl) return original.apply(this, arguments);
          calls[name]++;
          let result;
          try { result = original.apply(this, arguments); }
          catch (error) { totals.exceptions++; throw error; }
          record(name, arguments, result);
          return result;
        };
      }
    }
    canvasPrototype.getContext = function (type) {
      const gl = originalGetContext.apply(this, arguments);
      if (gl && type === 'webgl2' && this.id === canvasId) instrument(gl);
      return gl;
    };
    return {
      reset,
      snapshot() {
        return { contexts, canvas_id: canvasId, calls: { ...calls }, totals: { ...totals },
          incomplete_statuses: incomplete.map(item => ({ ...item })),
          incomplete_status_overflow: incompleteOverflow, multisample_samples: { ...multisampleSamples },
          scope: 'All intercepted native calls on owned canvas WebGL2 contexts; not uniquely backbuffer3d; call counts do not prove GL success',
          adds_driver_queries: false, consumes_get_error: false };
      },
    };
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = { installCanvasHook };
  else root.backbufferGlAudit = installCanvasHook(root.HTMLCanvasElement.prototype);
})(typeof globalThis !== 'undefined' ? globalThis : this);
