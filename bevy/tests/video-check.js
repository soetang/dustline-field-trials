'use strict';
// Decode the saved clip: an FPS label alone does not prove fluid gameplay.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const core=path.dirname(require.resolve('playwright-core/package.json'));
const {registry}=require(path.join(core,'lib/server/registry/index.js'));
const {PNG}=require(path.join(core,'lib/utilsBundle.js'));
const input=process.argv[2];
assert.ok(input,'Usage: node bevy/tests/video-check.js path/to/gameplay.webm');
assert.ok(fs.statSync(input).size<12*1024*1024,'Public video must stay below 12 MiB');
const before=fs.statSync(input);
const analysisRoot=path.resolve(__dirname,'../../artifacts/video-analysis');
fs.mkdirSync(analysisRoot,{recursive:true});
const output=fs.mkdtempSync(path.join(analysisRoot,'frames-'));
const decoded=spawnSync(registry.findExecutable('ffmpeg').executablePath(),[
  '-hide_banner','-loglevel','error','-n','-i',input,'-an','-vf','scale=144:96','-vsync','0',path.join(output,'%05d.png'),
],{encoding:'utf8',timeout:90000});
assert.equal(decoded.status,0,decoded.error?.message || decoded.stderr);
assert.equal(decoded.stderr.trim(),'','Reject decoder errors, including an unfinished recording');
const after=fs.statSync(input);
assert.equal(after.size,before.size,'Wait for encoding to finish before verifying the clip');
assert.equal(after.mtimeMs,before.mtimeMs,'The clip changed during verification');
const frames=fs.readdirSync(output).filter(file=>file.endsWith('.png')).sort();
assert.ok(frames.length>=250,'Show at least ten seconds of gameplay at 25 FPS');
let previous,changed=0,run=0,longestStillRun=0;
for(const frame of frames) {
  const current=PNG.sync.read(fs.readFileSync(path.join(output,frame)));
  if(previous) {
    let difference=0,count=0;
    // Measure the scene, not the ticking HUD, compass, minimap or ammo display.
    for(let y=24;y<72;y++)for(let x=40;x<120;x++)for(let c=0;c<3;c++) {
      const at=(y*144+x)*4+c;difference+=Math.abs(current.data[at]-previous.data[at]);count++;
    }
    if(difference/count>.45){changed++;run=0;}else{run++;longestStillRun=Math.max(run,longestStillRun);}
  }
  previous=current;
}
const report={input,frames:frames.length,changedFrames:changed,changedFraction:changed/(frames.length-1),longestStillRun,analysisDirectory:output};
fs.writeFileSync(path.join(output,'analysis.json'),JSON.stringify(report,null,2));
console.log('Decoded video motion:',report);
assert.ok(report.changedFraction>=.65,'At least 65% of frames must show scene motion for this movement demo');
