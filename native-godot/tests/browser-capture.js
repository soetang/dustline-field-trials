'use strict';

// CDP screenshot clipping resets Chromium's emulated DPR to 1 on some builds.
// Restore the test display even on failure; never change game graphics or time.
module.exports = async function captureCanvas(session, width, height, deviceScaleFactor) {
  try {
    const {data} = await session.send('Page.captureScreenshot', {
      format:'png', fromSurface:true, captureBeyondViewport:false,
      clip:{x:0,y:0,width,height,scale:deviceScaleFactor},
    });
    return Buffer.from(data,'base64');
  } finally {
    await session.send('Emulation.setDeviceMetricsOverride', {
      width,height,deviceScaleFactor,mobile:false,
    });
  }
};
