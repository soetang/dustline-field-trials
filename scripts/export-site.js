'use strict';
// Deliberate allowlist: never publish the workspace, credentials, caches, old
// Wasm releases, or assets without recorded provenance.
const fs = require('node:fs');
const path = require('node:path');
function exportSite(root = path.resolve(__dirname, '..'), exportCourtyard = () => require('../courtyard/tools/export-web-site')) {
  const out = path.join(root, '_site');
  const release = JSON.parse(fs.readFileSync(path.join(root,'bevy/web/current.json'),'utf8'));
  if (!/^\.\/web\/builds\/release-[\w-]+\/desert_strike\.js$/.test(release.entry)) throw new Error('Invalid release manifest');
  if (fs.existsSync(out)) throw new Error('_site already exists; move it aside before exporting a new release.');
  fs.mkdirSync(out);
  function copy(file, destination = file) {
    const target = path.join(out,destination);
    fs.mkdirSync(path.dirname(target),{recursive:true});
    fs.cpSync(path.join(root,file),target,{recursive:true});
  }
  // App ownership is local to the workspace; public URLs remain unchanged.
  for (const file of ['bevy.html','bevy.css','boot.js','client.js','touch-controls.js','licenses','assets/manifest.json','assets/textures/sources.json','web/current.json']) copy('bevy/'+file,file);
  copy('classic/index.html','classic.html');
  for (const file of ['styles.css','game.js']) copy('classic/'+file,file);
  for (const file of ['LICENSE','THIRD_PARTY.md']) copy(file);
  if (fs.existsSync(path.join(root,'docs/media/gameplay.webm'))) {
    copy('watch.html');
    for (const file of ['dustline-spawn.png','dustline-lane.png','gameplay.webm']) copy('docs/media/'+file);
  }
  // The sibling app URL is for source serving only, never the published site.
  const classicFallback = text => text.replaceAll('../classic/index.html','./classic.html').replaceAll('../classic/','./classic.html');
  const html = classicFallback(fs.readFileSync(path.join(out,'bevy.html'),'utf8'));
  fs.writeFileSync(path.join(out,'client.js'),classicFallback(fs.readFileSync(path.join(out,'client.js'),'utf8')));
  // Couple HTML, CSS and input scripts to one release, too. A cached older
  // client.js must not silently put a freshly deployed iPhone UI into mouse mode.
  let versionedHtml=html;
  const version=path.basename(path.dirname(release.entry));
  for(const file of ['bevy.css','client.js','touch-controls.js','boot.js']) {
    const name=file.replace(/(\.[^.]+)$/,`.${version}$1`);
    fs.copyFileSync(path.join(out,file),path.join(out,name));
    versionedHtml=versionedHtml.replaceAll(`"${file}"`,`"${name}"`);
  }
  fs.writeFileSync(path.join(out,'index.html'),versionedHtml);
  fs.writeFileSync(path.join(out,'bevy.html'),versionedHtml);
  copy('bevy/'+path.dirname(release.entry),path.dirname(release.entry));
  const assets = JSON.parse(fs.readFileSync(path.join(root,'bevy/assets/manifest.json'),'utf8'));
  for (const [name, group] of Object.entries(assets)) {
    if (!['MIT','CC0-1.0'].includes(group.license)) throw new Error(`Unreviewed asset license: ${name}`);
    for (const file of group.files) {
      if (file.includes('..') || path.isAbsolute(file)) throw new Error('Invalid asset path');
      copy('bevy/assets/' + file,'assets/' + file);
    }
  }
  fs.writeFileSync(path.join(out,'.nojekyll'),'');
  // The CLI always invokes Courtyard's real manifest verifier. Only isolated
  // Node fixtures inject this callback to avoid needing an engine build.
  exportCourtyard(out);
  function bytes(dir) { return fs.readdirSync(dir,{withFileTypes:true}).reduce((sum,f) => sum + (f.isDirectory()? bytes(path.join(dir,f.name)):fs.statSync(path.join(dir,f.name)).size),0); }
  const size = bytes(out);
  if (size > 900 * 1024 * 1024) throw new Error('Website exceeds safety budget');
  console.log(`Exported one release and licensed assets to _site (${(size/1024/1024).toFixed(1)} MiB).`);
  return out;
}

module.exports = {exportSite};
if (require.main === module) exportSite();
