'use strict';
// Fast contract checks catch missing HUD bindings and broken deployment assets.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'bevy.html'), 'utf8');
const js = fs.readFileSync(path.join(root, 'client.js'), 'utf8');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
assert.equal(ids.length, new Set(ids).size, 'HTML IDs must be unique');
const references = [...js.matchAll(/(?<![\w$])(?:\$|text|show)\('([^']+)'/g)].map(match => match[1]);
for (const id of references) assert.ok(ids.includes(id), `Missing HUD element #${id}`);
for (const file of ['client.js', 'bevy.css', 'bevy.html', 'boot.js']) assert.ok(fs.statSync(path.join(root, file)).size > 0, `Missing client file ${file}`);
const release = process.argv[2] ? {entry: process.argv[2]} : JSON.parse(fs.readFileSync(path.join(root, 'web/current.json'), 'utf8'));
assert.match(release.entry, /^\.\/web\/builds\/release-[\w-]+\/desert_strike\.js$/);
const entry = path.resolve(root, release.entry);
const glue = fs.readFileSync(entry, 'utf8');
const wasm = new WebAssembly.Module(fs.readFileSync(path.join(path.dirname(entry), 'desert_strike_bg.wasm')));
const imports = WebAssembly.Module.imports(wasm).filter(item => item.kind === 'function');
for (const item of imports) assert.ok(glue.includes(`${item.name}:`) || glue.includes(`'${item.name}':`), `Mismatched release: missing callable import ${item.name}`);
for (const [, relative] of glue.matchAll(/from\s+['"](.+?)['"]/g)) assert.ok(fs.existsSync(path.resolve(path.dirname(entry), relative)), `Missing generated module ${relative}`);
assert.equal([...html.matchAll(/data-slot="[0-3]"/g)].length, 4, 'All four weapons must be purchasable');
assert.match(js, /visibilitychange/, 'Background tabs must pause');
assert.match(js, /pointerlockchange/, 'Releasing mouse capture must pause');
const textureSources = JSON.parse(fs.readFileSync(path.join(root, 'assets/textures/sources.json'), 'utf8'));
assert.equal(textureSources.license, 'CC0-1.0');
assert.equal(textureSources.assets.length, 6);
for (const asset of textureSources.assets) {
  const bytes = fs.readFileSync(path.join(root, 'assets/textures', asset.file));
  assert.equal(bytes.length, asset.bytes, `Incomplete texture ${asset.file}`);
  assert.equal(crypto.createHash('md5').update(bytes).digest('hex'), asset.md5, `Texture checksum ${asset.file}`);
}
console.log(`Client checks passed: ${ids.length} unique IDs, ${new Set(references).size} HUD bindings, four buy controls, and ${imports.length} matched Wasm function imports.`);
console.log('Verified all six CC0 material textures against their source checksums.');
