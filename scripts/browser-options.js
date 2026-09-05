'use strict';
// CI keeps a portable software renderer. Opt into Mesa/WSLg hardware graphics
// when available; forcing SwiftShader on such hosts makes playtests needlessly slow.
exports.graphicsArgs=()=>[
  ...(process.env.DUSTLINE_GPU==='1'?['--use-gl=angle','--use-angle=gl']:['--use-angle=swiftshader']),
  '--enable-webgl','--ignore-gpu-blocklist',
];
exports.launchBrowser=chromium=>process.env.DUSTLINE_WINDOWS_BROWSER==='1'
  ? require('./windows-browser')(chromium)
  : chromium.launch({headless:true,args:exports.graphicsArgs()});
