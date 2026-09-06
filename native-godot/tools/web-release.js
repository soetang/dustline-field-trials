'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');

const files = [
  'index.html','index.js','index.wasm','index.pck','index.png',
  'index.audio.worklet.js','index.audio.position.worklet.js','LICENSE',
  'licenses/ASSET-SOURCES.txt','licenses/GODOT-LICENSE.txt','licenses/GODOT-COPYRIGHT.txt',
];
function inspect(directory) {
  const seen = [];
  function walk(relative = '') {
    for (const entry of fs.readdirSync(path.join(directory,relative), {withFileTypes:true})) {
      const file = path.posix.join(relative,entry.name);
      assert.ok(!entry.isSymbolicLink(), `Unexpected symlink: ${file}`);
      if (entry.isDirectory()) walk(file);
      else if (file !== 'release.json') seen.push(file);
    }
  }
  walk();
  assert.deepEqual(seen.sort(), [...files].sort(), 'Web export must contain only approved runtime files and notices');
  const html = fs.readFileSync(path.join(directory,'index.html'),'utf8');
  assert.match(html, /getMissingFeatures\(\{threads:false\}\)/);
  assert.doesNotMatch(html, /\$GODOT_/);
  const config = JSON.parse(html.match(/const config = (\{[^\n]+\});/)[1]);
  assert.equal(config.executable,'index');
  const result = {engine:'Godot 4.7.2', threadSupport:false, files:{}, uncompressedBytes:0, gzipBytes:0};
  for (const file of files) {
    const data = fs.readFileSync(path.join(directory,file));
    assert.ok(data.length>0, `Empty ${file}`);
    if (config.fileSizes[file] !== undefined) assert.equal(data.length, config.fileSizes[file], `Mismatched engine file: ${file}`);
    result.files[file] = {bytes:data.length, sha256:crypto.createHash('sha256').update(data).digest('hex')};
    result.uncompressedBytes += data.length;
    result.gzipBytes += zlib.gzipSync(data).length;
  }
  assert.ok(WebAssembly.validate(fs.readFileSync(path.join(directory,'index.wasm'))), 'Invalid engine Wasm');
  assert.equal(fs.readFileSync(path.join(directory,'index.pck')).subarray(0,4).toString(), 'GDPC', 'Invalid game resource pack');
  assert.ok(result.uncompressedBytes < 60*1024*1024, 'Web release exceeds 60 MiB uncompressed budget');
  assert.ok(result.gzipBytes < 25*1024*1024, 'Web release exceeds 25 MiB local gzip budget');
  return result;
}
function verify(directory) {
  const manifest = JSON.parse(fs.readFileSync(path.join(directory,'release.json'),'utf8'));
  assert.deepEqual(inspect(directory), manifest, 'Web release does not match its verified manifest');
  return manifest;
}
if (require.main === module) {
  const directory = path.resolve(process.argv[2]);
  const manifest = inspect(directory);
  fs.writeFileSync(path.join(directory,'release.json'), JSON.stringify(manifest,null,2)+'\n');
  console.log(`Verified Godot web release: ${(manifest.uncompressedBytes/1024/1024).toFixed(1)} MiB raw; ${(manifest.gzipBytes/1024/1024).toFixed(1)} MiB with local gzip (server transfer may differ).`);
}
module.exports = {files, inspect, verify};
