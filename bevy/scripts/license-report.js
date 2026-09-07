'use strict';
// Consumes Cargo's metadata on stdin. Generated notices contain no local paths.
const fs = require('node:fs');
const path = require('node:path');
const project = path.resolve(__dirname, '..');
let input = '';
process.stdin.on('data', chunk => input += chunk).on('end', async () => {
  const metadata = JSON.parse(input);
  const resolved = new Set(metadata.resolve.nodes.map(node => node.id));
  const packages = metadata.packages.filter(p => p.source && resolved.has(p.id)).sort((a,b) => a.name.localeCompare(b.name));
  const accepted = new Set(['MIT', 'Apache-2.0', 'Unicode-3.0', '0BSD', 'BSD-2-Clause', 'BSD-3-Clause', 'CC0-1.0', 'MIT-0', 'Zlib', 'Unlicense', 'LLVM-exception']);
  let output = 'Dustline: Field Trials — third-party Rust browser and build dependencies\n\nGenerated from Cargo.lock; upstream licenses apply independently.\n';
  const missing = [];
  for (const pkg of packages) {
    if (!pkg.license) throw new Error(`License missing: ${pkg.name}`);
    for (const token of pkg.license.replace(/[()/]/g,' ').split(/\s+/).filter(Boolean)) {
      if (!['AND','OR','WITH'].includes(token) && !accepted.has(token)) throw new Error(`Review new license: ${pkg.name}: ${pkg.license}`);
    }
    const dir = path.dirname(pkg.manifest_path);
    output += `\n${'='.repeat(72)}\n${pkg.name} ${pkg.version}\nLicense: ${pkg.license}\nSource: ${pkg.repository || 'https://crates.io/crates/' + pkg.name}\n`;
    const files = fs.readdirSync(dir).filter(f => /^(licen[sc]e|copying|copyright|notice|unlicense)([-._]|$)/i.test(f));
    if (pkg.license_file && !files.includes(pkg.license_file)) files.push(pkg.license_file);
    let notices = 0;
    for (const file of files.sort()) {
      const full = path.join(dir,file);
      if (fs.statSync(full).isFile()) { output += `\n--- ${file} ---\n${fs.readFileSync(full,'utf8')}\n`; notices++; }
    }
    if (!notices) {
      const saved = path.join(project, 'licenses/upstream', `${pkg.name}-${pkg.version}.txt`);
      if (!fs.existsSync(saved) && process.argv.includes('--fetch-missing')) {
        const vcs = JSON.parse(fs.readFileSync(path.join(dir,'.cargo_vcs_info.json'),'utf8'));
        const repo = pkg.repository.replace(/\.git$/, '');
        const base = repo.startsWith('https://github.com/')
          ? repo.replace('https://github.com/','https://raw.githubusercontent.com/') + '/' + vcs.git.sha1 + '/'
          : repo + '/-/raw/' + vcs.git.sha1 + '/';
        const candidates = ['LICENSE','LICENSE-MIT','LICENSE-APACHE','LICENSE.md','LICENSE.txt','COPYING','UNLICENSE'];
        const found = await Promise.all(candidates.map(async file => {
          const url = base + file;
          const response = await fetch(url, {signal:AbortSignal.timeout(20000)});
          if (!response.ok) return '';
          const text = await response.text();
          if (text.includes('<!DOCTYPE html>')) return '';
          return `Source: ${url}\n\n${text}\n`;
        }));
        if (found.some(Boolean)) {
          fs.mkdirSync(path.join(project,'licenses/upstream'),{recursive:true});
          fs.writeFileSync(saved,found.filter(Boolean).join('\n'));
        }
      }
      if (fs.existsSync(saved)) output += '\n' + fs.readFileSync(saved,'utf8');
      else missing.push(pkg.name);
    }
  }
  fs.mkdirSync(path.join(project,'licenses'),{recursive:true});
  fs.writeFileSync(path.join(project,'licenses/rust-dependencies.txt'),output);
  console.log(`Audited ${packages.length} open-source packages; saved licenses/rust-dependencies.txt.`);
  if (missing.length) console.log('No root notice packaged (review upstream):', missing.join(', '));
});
