'use strict';
// Test-only call accounting. No driver queries or timing claims; forward every
// argument and result unchanged. Installed only by the isolated HUD fixture.
(() => {
  const counts={};
  for (const name of ['createBuffer','deleteBuffer','createVertexArray','deleteVertexArray','bufferData']) {
    counts[name]=0;
    const original=WebGL2RenderingContext.prototype[name];
    WebGL2RenderingContext.prototype[name]=function(...args) {
      const result=Reflect.apply(original,this,args);
      counts[name]++;
      return result;
    };
  }
  window.hudBufferProbe={
    reset:()=>{for (const name of Object.keys(counts)) counts[name]=0;},
    snapshot:()=>({...counts}),
  };
})();
