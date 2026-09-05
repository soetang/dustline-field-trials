'use strict';
// Deliberate allowlist: never publish the workspace, credentials, caches, old
// Wasm releases, or assets without recorded provenance.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const out = path.join(root, '_site');
const release = JSON.parse(fs.readFileSync(path.join(root,'web/current.json'),'utf8'));
if (!/^\.\/web\/builds\/release-[\w-]+\/desert_strike\.js$/.test(release.entry)) throw new Error('Invalid release manifest');
if (fs.existsSync(out)) throw new Error('_site already exists; move it aside before exporting a new release.');
fs.mkdirSync(out);
function copy(file, destination = file) {
  const target = path.join(out,destination);
  fs.mkdirSync(path.dirname(target),{recursive:true});
  fs.cpSync(path.join(root,file),target,{recursive:true});
}
for (const file of ['bevy.html','bevy.css','boot.js','client.js','index.html','styles.css','game.js','LICENSE','THIRD_PARTY.md','licenses','assets/manifest.json','assets/textures/sources.json','web/current.json']) copy(file);
if (fs.existsSync(path.join(root,'docs/media/gameplay.webm'))) {
  copy('watch.html');
  for (const file of ['dustline-spawn.png','dustline-lane.png','gameplay.webm']) copy('docs/media/'+file);
}
// Website root goes straight to 3D; local index.html remains the classic prototype.
fs.renameSync(path.join(out,'index.html'),path.join(out,'classic.html'));
const html = fs.readFileSync(path.join(out,'bevy.html'),'utf8').replaceAll('./index.html','./classic.html');
fs.writeFileSync(path.join(out,'index.html'),html);
fs.writeFileSync(path.join(out,'bevy.html'),html);
fs.writeFileSync(path.join(out,'client.js'),fs.readFileSync(path.join(out,'client.js'),'utf8').replaceAll('./index.html','./classic.html'));
copy(path.dirname(release.entry));
const assets = JSON.parse(fs.readFileSync(path.join(root,'assets/manifest.json'),'utf8'));
for (const [name, group] of Object.entries(assets)) {
  if (!['MIT','CC0-1.0'].includes(group.license)) throw new Error(`Unreviewed asset license: ${name}`);
  if (name === 'experimentalWeapons') continue; // Not used by the renderer yet.
  for (const file of group.files) {
    if (file.includes('..') || path.isAbsolute(file)) throw new Error('Invalid asset path');
    copy('assets/' + file);
  }
}
fs.writeFileSync(path.join(out,'.nojekyll'),'');
function bytes(dir) { return fs.readdirSync(dir,{withFileTypes:true}).reduce((sum,f) => sum + (f.isDirectory()? bytes(path.join(dir,f.name)):fs.statSync(path.join(dir,f.name)).size),0); }
const size = bytes(out);
if (size > 900 * 1024 * 1024) throw new Error('Website exceeds safety budget');
console.log(`Exported one release and licensed assets to _site (${(size/1024/1024).toFixed(1)} MiB).`);
