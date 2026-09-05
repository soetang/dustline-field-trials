'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('boot.js','utf8');
const importLine='const { default: init } = await import(release.entry);';
assert.ok(source.includes(importLine));
const script=new vm.Script(`(async()=>{${source.replace(importLine,'const init = window.__init;')}})()`);
async function check({encoding,transforms=true,status=200}={}) {
  const label={textContent:''},errors=[],bytes=Uint8Array.from([0,97,115,109,1,0,0,0]);let initialized=false;
  const window={desertStrike:{fail:e=>errors.push(e.message)},__init:async({module_or_path})=>{
    assert.ok(module_or_path instanceof Response,'Initializer must receive a streamable Response');
    assert.equal(module_or_path.headers.get('content-type'),'application/wasm');
    const data=await module_or_path.arrayBuffer();assert.deepEqual(new Uint8Array(data),bytes);
    assert.ok(WebAssembly.validate(data));initialized=true;
  }};
  await script.runInNewContext({window,document:{getElementById:()=>label},location:{protocol:'https:',href:'https://example.github.io/dustline-field-trials/'},URL,Response,TransformStream:transforms?TransformStream:undefined,
    fetch:async url=>String(url).includes('current.json')?new Response(JSON.stringify({entry:'./web/builds/release-test/desert_strike.js'}),{status}):new Response(bytes,{headers:{'content-type':'application/wasm','content-length':encoding?'2':'8',...(encoding?{'content-encoding':encoding}:{})}}),
  });
  if(status===200){assert.ok(initialized);assert.deepEqual(errors,[]);if(transforms)assert.equal(label.textContent,'Preparing graphics and shaders…');}
  else {assert.ok(!initialized);assert.match(errors[0],/HTTP 503/);}
}
(async()=>{await check();await check({encoding:'gzip'});await check({transforms:false});await check({status:503});console.log('Streaming boot verified: Response handoff, intact bytes/MIME, compressed responses, fallback, and HTTP errors.');})().catch(e=>{console.error(e);process.exitCode=1;});
