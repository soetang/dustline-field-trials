'use strict';
// HTTP-only fixtures: no browser, engine, compiler or graphics context.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {createServer} = require('../scripts/serve');

(async () => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(),'dustline-serve-'));
  const write = (name,data) => { const file=path.join(fixture,name); fs.mkdirSync(path.dirname(file),{recursive:true}); fs.writeFileSync(file,data); };
  write('courtyard/builds/web-candidate.txt','courtyard-first');
  for (const release of ['first','next']) {
    write(`courtyard/builds/web-releases/courtyard-${release}/index.html`,'<a href="../../">Earlier edition</a>');
    write(`courtyard/builds/web-releases/courtyard-${release}/index.wasm`,release);
  }
  write('bevy/bevy.html','bevy'); write('bevy/boot.js','boot');
  write('bevy/web/current.json','{"entry":"./web/builds/release-one/desert_strike.js"}');
  write('bevy/web/builds/release-one/desert_strike.js','engine');
  write('classic/index.html','classic'); write('classic/game.js','game');
  write('.env','never serve'); write('bevy/Cargo.toml','never serve');
  fs.symlinkSync(path.join(fixture,'.env'),path.join(fixture,'bevy/web/escape'));
  fs.symlinkSync(path.join(fixture,'bevy/Cargo.toml'),path.join(fixture,'bevy/web/internal-escape'));
  const server = createServer(fixture);
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  let checks=0;
  const get=(url,options={})=>fetch(base+url,{redirect:'manual',...options});
  const equal=(a,b)=>{assert.equal(a,b);checks++;};
  try {
    equal((await get('/')).headers.get('location'),'/courtyard/');
    equal((await get('/courtyard/')).headers.get('location'),'/courtyard/courtyard-first/');
    equal(await (await get('/courtyard/courtyard-first/')).text(),'<a href="/bevy/bevy.html">Earlier edition</a>');
    write('courtyard/builds/web-candidate.txt','courtyard-next');
    equal((await get('/courtyard/')).headers.get('location'),'/courtyard/courtyard-next/');
    equal(await (await get('/courtyard/courtyard-first/index.wasm')).text(),'first');
    const wasm=await get('/courtyard/courtyard-next/index.wasm',{method:'HEAD'});
    equal(wasm.headers.get('content-type'),'application/wasm'); equal(wasm.headers.get('content-length'),'4'); equal(await wasm.text(),'');
    for (const [url,text] of [['/bevy/','bevy'],['/bevy/bevy.html','bevy'],['/bevy/boot.js','boot'],['/classic/','classic'],['/classic/game.js','game'],['/bevy/web/builds/release-one/desert_strike.js','engine']])
      equal(await (await get(url)).text(),text);
    for (const url of ['/.env','/.git/config','/bevy/Cargo.toml','/courtyard/project.godot',
      '/bevy/web/escape','/bevy/web/internal-escape','/bevy/web/%2e%2e%2fCargo.toml','/bevy/web/%2e%2e%2f%2e%2e%2f.env']) {
      assert.ok([403,404].includes((await get(url)).status),url); checks++;
    }
    equal((await get('/%')).status,400);
    equal((await get('/classic/',{method:'POST'})).status,405);
    write('courtyard/builds/web-candidate.txt','../../.env'); equal((await get('/courtyard/')).status,404);
    console.log(`APP_SERVER: ${checks}/${checks} passed; three apps, immutable release URLs, no workspace exposure`);
  } finally {
    await new Promise(resolve=>{ server.close(resolve); server.closeAllConnections(); });
    // Only the exact directory allocated by this fixture is removed.
    fs.rmSync(fixture,{recursive:true,force:true});
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
