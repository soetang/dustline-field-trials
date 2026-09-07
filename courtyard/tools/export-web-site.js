'use strict';
// Add only the current, verified Courtyard candidate to the existing site export.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {files, verify} = require('./web-release');
const project = path.resolve(__dirname,'..');
const out = path.resolve(project,'../_site/courtyard');
assert.ok(fs.existsSync(path.resolve(out,'../index.html')), 'Export the original browser site first');
assert.ok(!fs.existsSync(out), 'Courtyard already exists in _site; export into a fresh site');
const candidate = fs.readFileSync(path.join(project,'builds/web-candidate.txt'),'utf8').trim();
assert.match(candidate,/^courtyard-[\w-]+$/);
const source = path.join(project,'builds/web-releases',candidate);
verify(source);
const target = path.join(out,candidate);
for (const file of [...files,'release.json']) {
  fs.mkdirSync(path.dirname(path.join(target,file)),{recursive:true});
  fs.copyFileSync(path.join(source,file),path.join(target,file));
}
// The stable page pins every engine/resource/worklet URL to the same immutable
// release. Keep Godot's matching filenames within it, including on Pages subpaths.
const html = fs.readFileSync(path.join(target,'index.html'),'utf8');
assert.ok(!html.includes('<base '));
fs.writeFileSync(path.join(out,'index.html'),html.replace('<head>',`<head>\n  <base href="./${candidate}/">`));
console.log(`Courtyard preview added to _site/courtyard/ (${candidate}).`);
