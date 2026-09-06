'use strict';
// CI keeps a portable software renderer. Opt into Mesa/WSLg hardware graphics
// when available; forcing SwiftShader on such hosts makes playtests needlessly slow.
exports.graphicsArgs=()=>[
  ...(process.env.DUSTLINE_GPU==='1'?['--use-gl=angle','--use-angle=gl']:['--use-angle=swiftshader']),
  '--enable-webgl','--ignore-gpu-blocklist',
];
exports.launchBrowser=chromium=>{
  if(process.env.DUSTLINE_WINDOWS_BROWSER==='1') {
    // Windows headless Chrome can still confine the desktop cursor on pointer
    // lock. Never opt into host input as a side effect of requesting its GPU.
    if(process.env.DUSTLINE_ALLOW_HOST_INPUT!=='1')
      throw new Error('Windows pointer-lock tests can trap the desktop mouse. Use the default isolated Linux headless runner; host input requires DUSTLINE_ALLOW_HOST_INPUT=1.');
    return require('./windows-browser')(chromium);
  }
  // No connection to X11/Wayland/WSLg: even pointer-lock checks stay off the
  // user's desktop. Software-rendered results are not hardware FPS benchmarks.
  const env={...process.env};
  delete env.DISPLAY;
  delete env.WAYLAND_DISPLAY;
  return chromium.launch({headless:true,env,args:exports.graphicsArgs()});
};
