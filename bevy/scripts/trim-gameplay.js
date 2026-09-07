'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const repo = path.resolve(__dirname,'../..');
const info = JSON.parse(fs.readFileSync(path.join(repo,'artifacts/video-raw/capture.json'),'utf8'));
// Older capture manifests stored repository-relative paths; new ones are absolute.
const raw = path.resolve(repo,info.raw);
// Reuse the encoder installed with our pinned Playwright version; no new binary download.
const {registry} = require(path.join(path.dirname(require.resolve('playwright-core/package.json')),'lib/server/registry/index.js'));
const ffmpeg = process.env.FFMPEG_BIN || registry.findExecutable('ffmpeg').executablePath();
const duration = Math.min(30,info.clipEnd-info.clipStart);
if (!(duration>1)) throw new Error('Recording contains no gameplay');
const start = Math.max(info.clipStart,info.clipEnd-duration);
// Encoding is review-only: never silently replace the public clip with a bad run.
const output = path.join(info.directory ? path.resolve(repo,info.directory) : path.dirname(raw),'gameplay.webm');
execFileSync(ffmpeg,['-hide_banner','-loglevel','error','-n','-ss',String(start),'-i',raw,'-t',String(duration),'-an','-c:v','libvpx','-b:v','1000k','-crf','12','-deadline','good','-cpu-used','4',output],{stdio:'inherit'});
console.log(`Saved ${duration.toFixed(1)}s silent gameplay clip: ${output} (${(fs.statSync(output).size/1024/1024).toFixed(1)} MiB).`);
