'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname,'..','_site');
const exists = file => fs.existsSync(path.join(root,file));
for (const file of ['index.html','bevy.html','classic.html','styles.css','game.js','LICENSE','THIRD_PARTY.md','licenses/FiraMono-OFL.txt','licenses/rust-dependencies.txt']) assert.ok(exists(file),`Missing ${file}`);
for (const file of ['.git','.env','node_modules','.tools','target','src','bevy','classic','courtyard/scripts','assets/textures/sandstone-plaster.png']) assert.ok(!exists(file),`Private or unapproved content exported: ${file}`);
const html = fs.readFileSync(path.join(root,'index.html'),'utf8');
assert.equal(html,fs.readFileSync(path.join(root,'bevy.html'),'utf8'),'Both Bevy entries must pin the same release');
assert.match(html,/<title>Dustline: Field Trials<\/title>/);
assert.match(html,/href="\.\/classic.html"/);
assert.doesNotMatch(html,/href="\.\/index.html"/);
assert.doesNotMatch(html,/\.\.\/classic\//,'Published fallback must not escape the Pages subpath');
const client = fs.readFileSync(path.join(root,'client.js'),'utf8');
assert.match(client,/link\.href = ['"]\.\/classic\.html['"]/,'Runtime fallback must use the published classic URL');
assert.doesNotMatch(client,/\.\.\/classic\//,'Runtime fallback must not escape the Pages subpath');
for (const [,file] of html.matchAll(/(?:src|href)="((?:client|touch-controls|boot|bevy)\.release-[\w-]+\.(?:js|css))"/g)) assert.ok(exists(file),`Missing versioned browser asset ${file}`);
assert.match(html,/src="touch-controls\.release-[\w-]+\.js"/);
assert.match(fs.readFileSync(path.join(root,'classic.html'),'utf8'),/id="game"/);
assert.equal(fs.readdirSync(path.join(root,'web/builds')).length,1,'Publish only one immutable release');
const release = JSON.parse(fs.readFileSync(path.join(root,'web/current.json'),'utf8'));
assert.match(release.entry,/^\.\/web\/builds\/release-[\w-]+\/desert_strike\.js$/);
const version = path.basename(path.dirname(release.entry));
for (const file of ['bevy.css','client.js','touch-controls.js','boot.js']) {
  const versioned = file.replace(/(\.[^.]+)$/,`.${version}$1`);
  assert.ok(html.includes(`"${versioned}"`),`HTML must use the current ${file}`);
  assert.deepEqual(fs.readFileSync(path.join(root,versioned)),fs.readFileSync(path.join(root,file)),`Versioned ${file} must match its stable copy`);
}
const url = new URL(release.entry,'https://example.github.io/dustline-field-trials/');
assert.ok(url.pathname.startsWith('/dustline-field-trials/web/builds/'));
assert.ok(exists(release.entry));
const engine=new WebAssembly.Module(fs.readFileSync(path.join(root,path.dirname(release.entry),'desert_strike_bg.wasm')));
assert.ok(!WebAssembly.Module.imports(engine).some(i=>i.name==='dustline_capture_delta'),'Never publish the development-only capture clock');
const textures = JSON.parse(fs.readFileSync(path.join(root,'assets/textures/sources.json'),'utf8'));
for (const asset of textures.assets) {
  const data = fs.readFileSync(path.join(root,'assets/textures',asset.file));
  assert.equal(crypto.createHash('md5').update(data).digest('hex'),asset.md5);
}
if (exists('watch.html')) {
  for (const file of ['dustline-spawn.png','dustline-lane.png','gameplay.webm']) assert.ok(exists('docs/media/'+file));
  const clip = fs.readFileSync(path.join(root,'docs/media/gameplay.webm'));
  assert.equal(clip.readUInt32BE(0),0x1a45dfa3,'Video must be an actual WebM container');
  assert.ok(clip.length>10000 && clip.length<20*1024*1024);
}
const courtyardHtml = fs.readFileSync(path.join(root,'courtyard/index.html'),'utf8');
const courtyardRelease = courtyardHtml.match(/<base href="\.\/(courtyard-[\w-]+)\/">/)[1];
assert.deepEqual(fs.readdirSync(path.join(root,'courtyard')).sort(),[courtyardRelease,'index.html'].sort());
require('../courtyard/tools/web-release').verify(path.join(root,'courtyard',courtyardRelease));
const base = new URL(`./${courtyardRelease}/`,'https://example.github.io/dustline-field-trials/courtyard/');
assert.equal(new URL('../../',base).pathname,'/dustline-field-trials/','Courtyard fallback must return to the original game');
assert.equal(courtyardHtml,fs.readFileSync(path.join(root,'courtyard',courtyardRelease,'index.html'),'utf8').replace('<head>',`<head>\n  <base href="./${courtyardRelease}/">`),'Stable entry must pin the exact tested shell to its release');
console.log('Static export verified: original browser/mobile game, classic fallback, media, and one manifest-verified Courtyard release at a separate path.');
