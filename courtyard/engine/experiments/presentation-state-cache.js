'use strict';

// Isolated experiment, not loaded by the playable game. Emscripten's final
// offscreen blit reads these two states every frame. Shadow only state changed
// through this owned WebGL2 context; never replace validation or GL errors.
// Native prototype-method calls that bypass the wrappers require invalidate().
(function (root) {
  const SCISSOR_TEST = 0x0c11;
  const FRAMEBUFFER = 0x8d40;
  const READ_FRAMEBUFFER = 0x8ca8;
  const DRAW_FRAMEBUFFER = 0x8ca9;
  const DRAW_FRAMEBUFFER_BINDING = 0x8ca6; // FRAMEBUFFER_BINDING is an alias.
  const installed = new WeakMap();

  function install(gl) {
    if (installed.has(gl)) return installed.get(gl);
    const native = {};
    for (const name of ['getParameter', 'isContextLost', 'enable', 'disable',
      'createFramebuffer', 'bindFramebuffer', 'deleteFramebuffer']) {
      if (typeof gl[name] !== 'function') throw new TypeError(`Missing WebGL2 method: ${name}`);
      native[name] = gl[name];
    }
    let enabled = false;
    let scissorKnown = false, drawKnown = false, scissor, draw;
    let owned = new WeakSet();
    let hits = 0, fallbacks = 0;
    const object = value => value !== null && (typeof value === 'object' || typeof value === 'function');
    function rememberDraw(value) {
      draw = value;
      drawKnown = true;
      if (object(value)) owned.add(value);
    }
    function invalidate() { scissorKnown = false; drawKnown = false; }
    function contextChanged() { invalidate(); owned = new WeakSet(); }
    function invalidateBorrower(receiver) { installed.get(receiver)?.invalidate(); }
    gl.canvas?.addEventListener('webglcontextlost', contextChanged);
    gl.canvas?.addEventListener('webglcontextrestored', contextChanged);

    gl.getParameter = function (parameter) {
      if (this !== gl || (parameter !== SCISSOR_TEST && parameter !== DRAW_FRAMEBUFFER_BINDING))
        return native.getParameter.apply(this, arguments);
      const lost = native.isContextLost.call(gl);
      if (lost) contextChanged();
      const known = parameter === SCISSOR_TEST ? scissorKnown : drawKnown;
      if (enabled && known && !lost) {
        hits++;
        return parameter === SCISSOR_TEST ? scissor : draw;
      }
      fallbacks++;
      const value = native.getParameter.apply(gl, arguments);
      if (!lost) {
        if (parameter === SCISSOR_TEST) { scissor = value; scissorKnown = true; }
        else rememberDraw(value);
      }
      return value;
    };
    for (const name of ['enable', 'disable']) {
      gl[name] = function (capability) {
        const result = native[name].apply(this, arguments);
        if (this === gl) {
          if (capability === SCISSOR_TEST) { scissor = name === 'enable'; scissorKnown = true; }
          // A coercion can call application code; conservatively query again.
          else if (!Number.isInteger(capability) || capability < 0 || capability > 0xffffffff) scissorKnown = false;
        } else invalidateBorrower(this);
        return result;
      };
    }
    gl.createFramebuffer = function () {
      const result = native.createFramebuffer.apply(this, arguments);
      if (this === gl && object(result)) owned.add(result);
      else if (this !== gl) invalidateBorrower(this);
      return result;
    };
    gl.bindFramebuffer = function (target, framebuffer) {
      const result = native.bindFramebuffer.apply(this, arguments);
      if (this !== gl) { invalidateBorrower(this); return result; }
      if ((target === FRAMEBUFFER || target === DRAW_FRAMEBUFFER) &&
          (framebuffer === null || (object(framebuffer) && owned.has(framebuffer)))) {
        rememberDraw(framebuffer);
      } else if (target !== READ_FRAMEBUFFER) {
        // Invalid/deleted/foreign objects must not be assumed bound. Do not
        // consume getError(): the next getter obtains actual native state.
        drawKnown = false;
      }
      return result;
    };
    gl.deleteFramebuffer = function (framebuffer) {
      const result = native.deleteFramebuffer.apply(this, arguments);
      if (this === gl && object(framebuffer)) {
        if (drawKnown && draw === framebuffer) rememberDraw(null);
        owned.delete(framebuffer);
      } else if (this !== gl) invalidateBorrower(this);
      return result;
    };
    const controller = {
      setEnabled(value) { enabled = Boolean(value); },
      invalidate,
      resetStats() { hits = 0; fallbacks = 0; },
      getStats() { return { enabled, hits, fallbacks, scissorKnown, drawKnown }; },
      validate() {
        // Test boundary only: real synchronous queries, excluded from timing.
        // Do not repair the cache here and hide a discrepancy.
        const lost = native.isContextLost.call(gl);
        return {
          lost,
          scissor: !scissorKnown || lost || scissor === native.getParameter.call(gl, SCISSOR_TEST),
          draw: !drawKnown || lost || draw === native.getParameter.call(gl, DRAW_FRAMEBUFFER_BINDING),
        };
      },
    };
    installed.set(gl, controller);
    return controller;
  }

  function installCanvasHook(canvasPrototype) {
    const nativeGetContext = canvasPrototype.getContext;
    const controllers = new Set();
    let enabled = false;
    canvasPrototype.getContext = function (type) {
      const gl = nativeGetContext.apply(this, arguments);
      if (gl && type === 'webgl2' && this.id === 'canvas') {
        const controller = install(gl);
        controller.setEnabled(enabled);
        controllers.add(controller);
      }
      return gl;
    };
    return {
      setEnabled(value) { enabled = Boolean(value); for (const c of controllers) c.setEnabled(enabled); },
      resetStats() { for (const c of controllers) c.resetStats(); },
      snapshot() { return [...controllers].map(c => ({ ...c.getStats(), validation: c.validate() })); },
    };
  }

  const api = { install, installCanvasHook };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.presentationStateCache = installCanvasHook(root.HTMLCanvasElement.prototype);
})(typeof globalThis !== 'undefined' ? globalThis : this);
