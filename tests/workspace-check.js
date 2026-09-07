'use strict';
// Fast source-layout and isolated export checks: no engine build, renderer, or
// existing _site mutation. Courtyard's actual bundle verification is site-check.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {exportSite} = require('../scripts/export-site');
const root = path.resolve(__dirname,'..');
const read = file => fs.readFileSync(path.join(root,file),'utf8');
const browserFiles = ['bevy.html','bevy.css','boot.js','client.js','touch-controls.js'];
const classicFiles = ['index.html','styles.css','game.js'];
for (const file of ['bevy/Cargo.toml','bevy/src/main.rs','bevy/assets/manifest.json','bevy/licenses/rust-dependencies.txt','bevy/scripts/build-wasm.sh','classic/tests/smoke.js','courtyard/project.godot','courtyard/scripts/game.gd','courtyard/tools/export-web-site.js','courtyard/tools/web-release.js','LICENSE','THIRD_PARTY.md','watch.html']) {
  assert.ok(fs.existsSync(path.join(root,file)),`Missing app-owned/shared source: ${file}`);
}
for (const file of ['Cargo.toml','src','assets','web','licenses','bevy.html','bevy.css','client.js','boot.js','touch-controls.js','styles.css','game.js','native-godot']) {
  assert.ok(!fs.existsSync(path.join(root,file)),`App-owned source remains at the old root: ${file}`);
}
assert.match(read('bevy/bevy.html'),/href="\.\.\/classic\/"/);
assert.match(read('bevy/client.js'),/link\.href = '\.\.\/classic\/'/);
assert.match(read('classic/index.html'),/id="game"/);
for (const [app,html] of [['bevy','bevy.html'],['classic','index.html']]) {
  for (const [,url] of read(`${app}/${html}`).matchAll(/(?:src|href)="([^"?#]+)"/g)) {
    if (/^(?:[a-z]+:|\/|#)/i.test(url)) continue;
    assert.ok(fs.existsSync(path.resolve(root,app,url)),`Broken ${app} source reference: ${url}`);
  }
}
const actualManifest = path.join(root,'bevy/web/current.json');
if (fs.existsSync(actualManifest)) {
  const release = JSON.parse(fs.readFileSync(actualManifest,'utf8'));
  assert.match(release.entry,/^\.\/web\/builds\/release-[\w-]+\/desert_strike\.js$/);
  assert.ok(fs.existsSync(path.resolve(root,'bevy',release.entry)),'Generated entry must resolve from the Bevy source root');
}

const temp = fs.mkdtempSync(path.join(os.tmpdir(),'dustline-workspace-export-'));
let cases = 0;
function put(base,file,data) {
  fs.mkdirSync(path.dirname(path.join(base,file)),{recursive:true});
  fs.writeFileSync(path.join(base,file),data);
}
function fixture(name) {
  const base = path.join(temp,name);
  for (const file of [...browserFiles.map(file=>'bevy/'+file),...classicFiles.map(file=>'classic/'+file),'LICENSE','THIRD_PARTY.md','watch.html','bevy/licenses/FiraMono-OFL.txt','bevy/licenses/rust-dependencies.txt']) {
    put(base,file,fs.readFileSync(path.join(root,file)));
  }
  put(base,'bevy/web/current.json',JSON.stringify({entry:'./web/builds/release-fixture/desert_strike.js'}));
  // Opaque paired bytes are sufficient to test copying; nothing compiles them.
  put(base,'bevy/web/builds/release-fixture/desert_strike.js','export const fixture = "matching-release";\n');
  put(base,'bevy/web/builds/release-fixture/desert_strike_bg.wasm',Buffer.from([0,97,115,109,1,0,0,0]));
  put(base,'bevy/web/builds/release-old/desert_strike_bg.wasm','must not publish');
  put(base,'bevy/assets/manifest.json',JSON.stringify({model:{license:'MIT',files:['models/operator.glb']},texture:{license:'CC0-1.0',files:['textures/floor.jpg']}}));
  put(base,'bevy/assets/models/operator.glb','approved model bytes');
  put(base,'bevy/assets/textures/floor.jpg','approved texture bytes');
  put(base,'bevy/assets/textures/sources.json','{"assets":[]}\n');
  for (const file of ['.env','bevy/.env','bevy/src/private.rs','bevy/target/cache','bevy/assets/textures/unreviewed.png','courtyard/scripts/private.gd','web/current.json','assets/manifest.json','index.html']) put(base,file,'must not publish');
  return base;
}
function check(name,run) { run(fixture(name)); cases++; }
try {
  check('public-layout',base => {
    let calls = 0;
    const out = exportSite(base,dir => {
      calls++;
      assert.equal(dir,path.join(base,'_site'));
      assert.ok(fs.existsSync(path.join(dir,'index.html')),'Bevy must export before Courtyard');
    });
    assert.equal(calls,1);
    const output = file => fs.readFileSync(path.join(out,file));
    const source = file => fs.readFileSync(path.join(base,file));
    let html = source('bevy/bevy.html').toString().replaceAll('../classic/','./classic.html');
    for (const file of browserFiles.filter(file=>file!=='bevy.html')) {
      const versioned = file.replace(/(\.[^.]+)$/,'.release-fixture$1');
      html = html.replaceAll(`"${file}"`,`"${versioned}"`);
      const expected = file==='client.js' ? Buffer.from(source('bevy/'+file).toString().replaceAll('../classic/','./classic.html')) : source('bevy/'+file);
      assert.deepEqual(output(file),expected);
      assert.deepEqual(output(versioned),expected);
    }
    assert.equal(output('index.html').toString(),html);
    assert.equal(output('bevy.html').toString(),html);
    assert.deepEqual(output('classic.html'),source('classic/index.html'));
    for (const file of ['styles.css','game.js']) assert.deepEqual(output(file),source('classic/'+file));
    for (const file of ['LICENSE','THIRD_PARTY.md']) assert.deepEqual(output(file),source(file));
    for (const file of ['licenses/FiraMono-OFL.txt','licenses/rust-dependencies.txt','web/current.json','assets/manifest.json','assets/textures/sources.json','assets/models/operator.glb','assets/textures/floor.jpg','web/builds/release-fixture/desert_strike.js','web/builds/release-fixture/desert_strike_bg.wasm']) assert.deepEqual(output(file),source('bevy/'+file));
    assert.deepEqual(fs.readdirSync(path.join(out,'web/builds')),['release-fixture']);
    for (const file of ['bevy','classic','src','target','.env','assets/textures/unreviewed.png','watch.html','docs']) assert.ok(!fs.existsSync(path.join(out,file)),`Unexpected export: ${file}`);
    assert.ok(fs.existsSync(path.join(out,'.nojekyll')));
    const publicBase = 'https://example.github.io/dustline-field-trials/';
    assert.equal(new URL('./classic.html',publicBase).pathname,'/dustline-field-trials/classic.html');
    assert.equal(new URL(JSON.parse(output('web/current.json')).entry,publicBase).pathname,'/dustline-field-trials/web/builds/release-fixture/desert_strike.js');
    for (const file of [...browserFiles.map(file=>'bevy/'+file),...classicFiles.map(file=>'classic/'+file)]) assert.deepEqual(source(file),fs.readFileSync(path.join(root,file)),'Export must not edit source');
    put(out,'keep.txt','existing site');
    assert.throws(()=>exportSite(base,()=>{ throw Error('must not run'); }),/already exists/);
    assert.equal(output('keep.txt').toString(),'existing site');
    assert.equal(output('index.html').toString(),html);
  });
  check('optional-media-and-explicit-fallback',base => {
    for (const file of ['bevy/bevy.html','bevy/client.js']) put(base,file,fs.readFileSync(path.join(base,file),'utf8').replaceAll('../classic/','../classic/index.html'));
    for (const file of ['dustline-spawn.png','dustline-lane.png','gameplay.webm']) put(base,'docs/media/'+file,'opaque fixture '+file);
    put(base,'docs/media/private.txt','must not publish');
    const out = exportSite(base,()=>{});
    for (const file of ['watch.html','docs/media/dustline-spawn.png','docs/media/dustline-lane.png','docs/media/gameplay.webm']) assert.deepEqual(fs.readFileSync(path.join(out,file)),fs.readFileSync(path.join(base,file)));
    assert.ok(!fs.existsSync(path.join(out,'docs/media/private.txt')));
    for (const file of ['index.html','bevy.html','client.js','client.release-fixture.js']) {
      const text = fs.readFileSync(path.join(out,file),'utf8');
      assert.ok(text.includes('./classic.html'));
      assert.ok(!text.includes('../classic/') && !text.includes('./classic.htmlindex.html'));
    }
  });
  check('invalid-release',base => {
    put(base,'bevy/web/current.json','{"entry":"../web/builds/release-old/desert_strike.js"}');
    assert.throws(()=>exportSite(base,()=>{ throw Error('must not run'); }),/Invalid release manifest/);
    assert.ok(!fs.existsSync(path.join(base,'_site')));
  });
  check('unreviewed-license',base => {
    put(base,'bevy/assets/manifest.json','{"unreviewed":{"license":"unknown","files":["textures/unreviewed.png"]}}');
    assert.throws(()=>exportSite(base,()=>{ throw Error('must not run'); }),/Unreviewed asset license/);
    assert.ok(!fs.existsSync(path.join(base,'_site/assets/textures/unreviewed.png')));
  });
  for (const [name,file] of [['parent-path','../.env'],['absolute-path','/private.png']]) check(name,base => {
    put(base,'bevy/assets/manifest.json',JSON.stringify({invalid:{license:'MIT',files:[file]}}));
    assert.throws(()=>exportSite(base,()=>{ throw Error('must not run'); }),/Invalid asset path/);
  });
  check('courtyard-verification-failure',base => {
    const failure = new Error('Courtyard fixture verification failed');
    assert.throws(()=>exportSite(base,()=>{ throw failure; }),error=>error===failure);
  });
} finally {
  // Only this test's mkdtemp directory; never the workspace or existing _site.
  fs.rmSync(temp,{recursive:true,force:true});
}
console.log(`Workspace source ownership and ${cases} isolated export fixtures passed; existing _site untouched.`);
