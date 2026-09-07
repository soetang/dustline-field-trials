'use strict';

// Fast, offline fixtures only: no engine, network, compiler, ZIP extraction or
// generated executable is run. Source pins are never overridden for fixtures.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const {spawnSync} = require('node:child_process');
const review = require('./engine-template-review.js');
const {PINS, FILES, ZIP_NAMES, MAX_ZIP} = review;
const expected = {run: '34150171372', sha: 'a'.repeat(40)};
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const clone = value => JSON.parse(JSON.stringify(value));
let passed = 0;
function check(name, action) {
  try { action(); passed++; } catch (error) { error.message = `${name}: ${error.message}`; throw error; }
}
function rejected(name, action, pattern) { check(name, () => assert.throws(action, pattern)); }

// Deliberately separate, bit-at-a-time fixture CRC implementation.
function crc32(bytes) {
  let result = 0xffffffff;
  for (const byte of bytes) {
    result ^= byte;
    for (let bit = 0; bit < 8; bit++) result = (result >>> 1) ^ ((result & 1) ? 0xedb88320 : 0);
  }
  return (result ^ 0xffffffff) >>> 0;
}
function members(marker) {
  return new Map(ZIP_NAMES.map(name => [name, name === 'godot.wasm'
    ? Buffer.from([0, 97, 115, 109, 1, 0, 0, 0, marker])
    : Buffer.from(name === 'godot.js' ? 'same paired JavaScript\n' : `fixture ${name}\n`)]));
}

// Builds small ordinary ZIP fixtures in memory, including descriptor variants.
function zip(entries, options = {}) {
  const locals = [], centrals = [];
  let offset = 0;
  for (const [index, [name, data]] of [...entries].entries()) {
    const nameBytes = Buffer.from(name), method = options.method ?? 8;
    const descriptor = options.descriptor ?? false;
    const compressed = method === 8 ? zlib.deflateRawSync(data) : Buffer.from(data);
    const flags = 0x800 | (descriptor ? 8 : 0), crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4);
    local.writeUInt16LE(flags, 6); local.writeUInt16LE(method, 8);
    if (!descriptor) {
      local.writeUInt32LE(crc, 14); local.writeUInt32LE(compressed.length, 18); local.writeUInt32LE(data.length, 22);
    }
    local.writeUInt16LE(nameBytes.length, 26);
    const tail = Buffer.alloc(descriptor ? (options.signature === false ? 12 : 16) : 0);
    if (descriptor) {
      const start = tail.length === 16 ? 4 : 0;
      if (start) tail.writeUInt32LE(0x08074b50, 0);
      tail.writeUInt32LE(crc, start); tail.writeUInt32LE(compressed.length, start + 4); tail.writeUInt32LE(data.length, start + 8);
    }
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(0x0314, 4); central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8); central.writeUInt16LE(method, 10);
    central.writeUInt32LE(crc, 16); central.writeUInt32LE(compressed.length, 20); central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(options.attributes ?? ((0o100644 << 16) >>> 0), 38);
    central.writeUInt32LE(offset, 42);
    if (options.mutate) options.mutate({index, local, central, tail, compressed});
    locals.push(local, nameBytes, compressed, tail); centrals.push(central, nameBytes);
    offset += local.length + nameBytes.length + compressed.length + tail.length;
  }
  const centralBytes = Buffer.concat(centrals), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.size ?? entries.length, 8);
  end.writeUInt16LE(entries.size ?? entries.length, 10); end.writeUInt32LE(centralBytes.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, centralBytes, end]);
}

const originals = members(11), candidates = members(22);
const archives = {baseline: zip(originals), patched: zip(candidates)};
function manifest() {
  const sourceKeys = ['tag', 'revision', 'url', 'archive_sha256', 'original_cpp_sha256', 'patched_cpp_sha256'];
  const toolKeys = ['emsdk_revision', 'emscripten', 'emscripten_revision', 'scons'];
  return {
    repository_revision: expected.sha, workflow_run: expected.run,
    source: Object.fromEntries(sourceKeys.map(key => [key, PINS[key]])),
    patch: {file: FILES.patch, sha256: PINS.patch_sha256},
    toolchain: {...Object.fromEntries(toolKeys.map(key => [key, PINS[key]])),
      compiler_version: 'emcc (Emscripten gcc/clang-like replacement + linker emulating GNU ld) 4.0.20 (fixture)\nCopyright',
      python: 'Python 3.12.10', node: 'v24.19.0'},
    flags: ['platform=web', 'target=template_release', 'threads=no', 'production=yes', '-j2'],
    pythonhashseed: 0, order: 'baseline, then only the patch; same incremental build directory',
    templates: ['baseline', 'patched'].map((key, index) => ({
      name: index ? 'remove-ssao-depth-copy' : 'baseline', zip: FILES[key], zip_sha256: hash(archives[key]),
      js_sha256: hash((index ? candidates : originals).get('godot.js')),
      wasm_sha256: hash((index ? candidates : originals).get('godot.wasm')),
    })),
    limitations: 'Fixture metadata; not an attestation or performance result.',
  };
}
function badManifest(name, mutate, pattern) {
  rejected(name, () => { const value = manifest(); mutate(value); review.validateManifest(value, expected); }, pattern);
}

check('fixture CRC known vector', () => assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926));
check('all source/tool/patch pins match build script', () => {
  const source = fs.readFileSync(path.join(__dirname, '../tools/build-engine-review.sh'), 'utf8');
  const keys = {tag: 'godot_tag', revision: 'godot_revision', archive_sha256: 'source_sha256',
    original_cpp_sha256: 'original_cpp_sha256', patched_cpp_sha256: 'patched_cpp_sha256', patch_sha256: 'patch_sha256',
    emsdk_revision: 'emsdk_revision', emscripten: 'emscripten_version', emscripten_revision: 'emscripten_revision', scons: 'scons_version'};
  for (const [key, shell] of Object.entries(keys)) assert.ok(source.includes(`${shell}='${PINS[key]}'`), key);
  assert.ok(source.includes('flags=(platform=web target=template_release threads=no production=yes "-j$jobs")'));
  assert.ok(source.includes('case "$jobs" in 2|4)'));
  assert.equal(hash(fs.readFileSync(path.join(__dirname, '../engine/patches', FILES.patch))), PINS.patch_sha256);
});
check('known manifest accepted and detached', () => {
  const value = manifest(), accepted = review.validateManifest(value, expected);
  assert.deepEqual(accepted, value); value.flags[0] = 'changed'; value.templates[0].zip = 'changed';
  assert.equal(accepted.flags[0], 'platform=web'); assert.equal(accepted.templates[0].zip, FILES.baseline);
});
check('reviewed four-job build accepted', () => {
  const value = manifest(); value.flags[4] = '-j4'; review.validateManifest(value, expected);
});
check('Node version from SDK is not assumed setup-node version', () => {
  const value = manifest(); value.toolchain.node = 'v22.22.0'; review.validateManifest(value, expected);
});
for (const key of Object.keys(manifest())) badManifest(`missing ${key}`, value => { delete value[key]; });
for (const key of Object.keys(manifest().source)) badManifest(`pinned source ${key}`, value => { value.source[key] += 'x'; });
for (const key of ['emsdk_revision', 'emscripten', 'emscripten_revision', 'scons'])
  badManifest(`pinned toolchain ${key}`, value => { value.toolchain[key] += 'x'; });
for (const [name, mutate] of [
  ['extra field', value => { value.untrusted = true; }],
  ['wrong run', value => { value.workflow_run = '1'; }],
  ['numeric run', value => { value.workflow_run = Number(expected.run); }],
  ['wrong head', value => { value.repository_revision = 'b'.repeat(40); }],
  ['short head', value => { value.repository_revision = expected.sha.slice(0, 7); }],
  ['extra source field', value => { value.source.other_patch = 'x'; }],
  ['patch path traversal', value => { value.patch.file = '../remove-ssao-depth-copy.patch'; }],
  ['old backbuffer patch', value => { value.patch.file = 'cache-backbuffer.patch'; }],
  ['patch self-declared hash', value => { value.patch.sha256 = hash(Buffer.from('unreviewed')); }],
  ['extra toolchain field', value => { value.toolchain.extra = true; }],
  ['wrong compiler banner', value => { value.toolchain.compiler_version = 'emcc (fixture) 4.0.21'; }],
  ['compiler substring spoof', value => { value.toolchain.compiler_version = 'other compiler\nemcc (fixture) 4.0.20'; }],
  ['unbounded compiler', value => { value.toolchain.compiler_version = 'x'.repeat(8193); }],
  ['compiler NUL', value => { value.toolchain.compiler_version += '\0'; }],
  ['wrong Python', value => { value.toolchain.python = 'Python 3.13.0'; }],
  ['invalid Node', value => { value.toolchain.node = 'node path/to/file'; }],
  ['extra flags', value => { value.flags.push('optimize=none'); }],
  ['reordered flags', value => { value.flags.reverse(); }],
  ['different jobs', value => { value.flags[4] = '-j8'; }],
  ['threads on', value => { value.flags[2] = 'threads=yes'; }],
  ['debug target', value => { value.flags[1] = 'target=template_debug'; }],
  ['different hash seed', value => { value.pythonhashseed = 1; }],
  ['different build order', value => { value.order = 'two independent sources'; }],
  ['no limitation', value => { value.limitations = ''; }],
  ['three templates', value => { value.templates.push(value.templates[0]); }],
  ['missing pair', value => { value.templates.pop(); }],
  ['swapped templates', value => { value.templates.reverse(); }],
  ['duplicate templates', value => { value.templates[1] = value.templates[0]; }],
  ['template traversal', value => { value.templates[0].zip = '../baseline-web-nothreads.zip'; }],
  ['template absolute path', value => { value.templates[0].zip = '/tmp/baseline-web-nothreads.zip'; }],
  ['template extra path', value => { value.templates[0].path = '/tmp'; }],
  ['missing member hash', value => { delete value.templates[0].js_sha256; }],
  ['malformed member hash', value => { value.templates[0].js_sha256 = 'f'.repeat(63); }],
  ['uppercase member hash', value => { value.templates[0].js_sha256 = 'F'.repeat(64); }],
  ['identical declared Wasm', value => { value.templates[1].wasm_sha256 = value.templates[0].wasm_sha256; }],
]) badManifest(name, mutate);

for (const options of [{}, {method: 0}, {descriptor: true}, {descriptor: true, signature: false}, {attributes: 0}]) {
  check(`ZIP decoded exactly ${JSON.stringify(options)}`, () => assert.deepEqual(review.readTemplateZip(zip(originals, options)), originals));
}
check('ZIP comment accepted without extraction', () => {
  const bytes = Buffer.from(archives.baseline); bytes.writeUInt16LE(3, bytes.length - 2);
  assert.deepEqual(review.readTemplateZip(Buffer.concat([bytes, Buffer.from('abc')])), originals);
});
for (const name of ['../godot.js', '/godot.js', 'sub/godot.js', 'sub\\godot.js', 'godot.js\0', 'GODOT.js']) {
  rejected(`ZIP unsafe name ${JSON.stringify(name)}`, () => review.readTemplateZip(zip([...originals].map((entry, index) => index ? entry : [name, entry[1]]))));
}
rejected('duplicate ZIP name', () => review.readTemplateZip(zip([...originals].map((entry, index) => index === 1 ? ['godot.js', entry[1]] : entry))));
rejected('missing ZIP member', () => review.readTemplateZip(zip([...originals].slice(1))));
rejected('extra ZIP member', () => review.readTemplateZip(zip([...originals, ['extra.js', Buffer.from('extra')]])));
for (const [name, attributes] of [['symlink', (0o120777 << 16) >>> 0], ['directory', (0o040755 << 16) >>> 0], ['DOS directory', 16], ['socket', (0o140644 << 16) >>> 0]]) {
  rejected(`ZIP ${name}`, () => review.readTemplateZip(zip(originals, {attributes})));
}
for (const [name, mutate] of [
  ['encrypted', ({local, central}) => { local.writeUInt16LE(0x801, 6); central.writeUInt16LE(0x801, 8); }],
  ['unknown flags', ({local, central}) => { local.writeUInt16LE(0x810, 6); central.writeUInt16LE(0x810, 8); }],
  ['unsupported method', ({local, central}) => { local.writeUInt16LE(99, 8); central.writeUInt16LE(99, 10); }],
  ['central ZIP64', ({central}) => central.writeUInt16LE(45, 6)],
  ['local ZIP64', ({local}) => local.writeUInt16LE(45, 4)],
  ['local flags mismatch', ({local}) => local.writeUInt16LE(0, 6)],
  ['local method mismatch', ({local}) => local.writeUInt16LE(0, 8)],
  ['local CRC mismatch', ({local}) => local.writeUInt32LE(42, 14)],
  ['local size mismatch', ({local}) => local.writeUInt32LE(42, 22)],
  ['local name mismatch', ({local}) => local.writeUInt16LE(1, 26)],
  ['split member', ({central}) => central.writeUInt16LE(1, 34)],
  ['expanded limit', ({central}) => central.writeUInt32LE(MAX_ZIP + 1, 24)],
  ['compressed bounds', ({central}) => central.writeUInt32LE(0xffffffff, 20)],
  ['invalid local offset', ({central}) => central.writeUInt32LE(0xffffffff, 42)],
  ['truncated central name', ({central}) => central.writeUInt16LE(65535, 28)],
  ['deflate output exceeds advertised bound', ({local, central}) => { local.writeUInt32LE(1, 22); central.writeUInt32LE(1, 24); }],
]) rejected(`ZIP ${name}`, () => review.readTemplateZip(zip(originals, {mutate: item => { if (item.index === 0) mutate(item); }})));
rejected('ZIP descriptor mismatch', () => review.readTemplateZip(zip(originals, {descriptor: true, mutate: ({tail}) => tail.writeUInt32LE(42, 4)})));
rejected('ZIP decoded CRC mismatch', () => review.readTemplateZip(zip(originals, {method: 0, mutate: ({compressed}) => { compressed[0] ^= 1; }})));
const goodArchives = {baseline: zip(members(11)), patched: zip(members(22))};
for (const [name, mutate] of [
  ['trailing bytes', bytes => Buffer.concat([bytes, Buffer.from('trailing')])],
  ['truncated', bytes => bytes.subarray(0, bytes.length - 1)],
  ['multiple disks', bytes => { bytes.writeUInt16LE(1, bytes.length - 18); return bytes; }],
  ['split entries', bytes => { bytes.writeUInt16LE(6, bytes.length - 14); return bytes; }],
  ['central bounds', bytes => { bytes.writeUInt32LE(1, bytes.length - 6); return bytes; }],
]) rejected(`ZIP ${name}`, () => review.readTemplateZip(mutate(Buffer.from(goodArchives.baseline))));
rejected('non-buffer ZIP', () => review.readTemplateZip('not a ZIP'));
rejected('empty ZIP', () => review.readTemplateZip(Buffer.alloc(0)));

check('actual pair embedded hashes', () => {
  const value = manifest();
  for (const [index, key] of ['baseline', 'patched'].entries()) value.templates[index].zip_sha256 = hash(goodArchives[key]);
  const result = review.verifyTemplates(value, goodArchives);
  assert.equal(result.baseline.wasm_sha256, value.templates[0].wasm_sha256);
  assert.equal(result.patched.js_sha256, value.templates[1].js_sha256);
});
check('safe trusted fake ZIP reader API', () => {
  const value = manifest(), tiny = {baseline: Buffer.from('base'), patched: Buffer.from('patch')};
  value.templates[0].zip_sha256 = hash(tiny.baseline); value.templates[1].zip_sha256 = hash(tiny.patched);
  let reads = 0;
  review.verifyTemplates(value, tiny, bytes => { reads++; return members(bytes.equals(tiny.baseline) ? 11 : 22); });
  assert.equal(reads, 2);
});
for (const [name, mutate] of [
  ['archive tamper', (value, bytes) => { bytes.baseline = Buffer.from('tampered ZIP'); }],
  ['swapped actual pairs', (value, bytes) => { [bytes.baseline, bytes.patched] = [bytes.patched, bytes.baseline]; }],
  ['embedded JS mismatch', value => { value.templates[0].js_sha256 = 'f'.repeat(64); }],
  ['embedded Wasm mismatch', value => { value.templates[1].wasm_sha256 = 'f'.repeat(64); }],
]) rejected(name, () => {
  const value = manifest(), bytes = {...goodArchives};
  for (const [index, key] of ['baseline', 'patched'].entries()) value.templates[index].zip_sha256 = hash(bytes[key]);
  mutate(value, bytes); review.verifyTemplates(value, bytes);
});
for (const [name, reader] of [
  ['plain object result', () => ({})],
  ['missing member', () => new Map([...members(11)].slice(1))],
  ['extra member', () => new Map([...members(11), ['../evil', Buffer.from('x')]])],
  ['non-buffer member', () => { const result = members(11); result.set('godot.html', 'text'); return result; }],
  ['empty member', () => { const result = members(11); result.set('godot.html', Buffer.alloc(0)); return result; }],
]) rejected(`fake ZIP reader ${name}`, () => review.verifyTemplates(manifest(), archives, reader));
rejected('matching arbitrary bytes are not Wasm', () => {
  const value = manifest(), files = members(11); files.set('godot.wasm', Buffer.from('not wasm'));
  value.templates[0].wasm_sha256 = hash(files.get('godot.wasm'));
  review.verifyTemplates(value, archives, () => files);
});
rejected('identical actual Wasm despite matching per-file hashes', () => {
  const value = manifest(); value.templates[1].wasm_sha256 = value.templates[0].wasm_sha256;
  review.verifyTemplates(value, archives, () => members(11));
}, /actually differ/);

check('CLI arguments separated and equals forms', () => {
  assert.deepEqual(review.parseArguments(['folder', '--run', expected.run, '--sha', expected.sha]), {directory: 'folder', expected});
  assert.deepEqual(review.parseArguments([`--sha=${expected.sha}`, 'folder', `--run=${expected.run}`]), {directory: 'folder', expected});
});
for (const args of [[], ['folder'], ['folder', '--run'], ['folder', '--run='],
  ['folder', '--run=01', `--sha=${expected.sha}`], ['folder', '--run=1e3', `--sha=${expected.sha}`],
  ['folder', '--run=1', '--sha=short'], ['folder', '--run=1', `--sha=${'F'.repeat(40)}`],
  ['folder', '--run=1', `--sha=${expected.sha}`, '--run=2'],
  ['folder', '--run=1', `--sha=${expected.sha}`, '--sha=bad'],
  ['folder', '--run=1', `--sha=${expected.sha}`, 'another'],
  ['folder', '--run=1', `--sha=${expected.sha}`, '--readZip=unsafe'],
  ['--run=1', `--sha=${expected.sha}`]]) {
  rejected(`CLI rejects ${args.join(' ')}`, () => review.parseArguments(args));
}

const temporary = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'engine-template-review-check-'));
try {
  const directory = path.join(temporary, 'artifact'); fs.mkdirSync(directory);
  const outside = path.join(temporary, 'outside'); fs.writeFileSync(outside, 'not an artifact');
  const populate = () => {
    fs.writeFileSync(path.join(directory, 'manifest.json'), JSON.stringify(manifest()));
    for (const [key, filename] of Object.entries(FILES)) fs.writeFileSync(path.join(directory, filename), archives[key] ?? Buffer.from('unreviewed source'));
  };
  populate();
  rejected('self-declared source hashes cannot authorize unrelated actual bytes', () => review.verifyArtifact(directory, expected), /Actual original bytes differ/);
  check('source pin checked before fake ZIP reader', () => {
    let called = false;
    assert.throws(() => review.verifyArtifact(directory, expected, {readZip: () => { called = true; return originals; }}));
    assert.equal(called, false);
  });
  for (const filename of ['manifest.json', ...Object.values(FILES)]) {
    const target = path.join(directory, filename), saved = fs.readFileSync(target);
    fs.unlinkSync(target); fs.symlinkSync(outside, target);
    rejected(`artifact symlink ${filename}`, () => review.verifyArtifact(directory, expected), /Regular unlinked artifact file required/);
    fs.unlinkSync(target); fs.linkSync(outside, target);
    rejected(`artifact hardlink ${filename}`, () => review.verifyArtifact(directory, expected), /Regular unlinked artifact file required/);
    fs.unlinkSync(target); fs.mkdirSync(target);
    rejected(`artifact directory member ${filename}`, () => review.verifyArtifact(directory, expected), /Regular unlinked artifact file required/);
    fs.rmdirSync(target);
    rejected(`missing artifact ${filename}`, () => review.verifyArtifact(directory, expected), /ENOENT/);
    fs.writeFileSync(target, saved);
  }
  const alias = path.join(temporary, 'alias'); fs.symlinkSync(directory, alias);
  rejected('root symlink', () => review.verifyArtifact(alias, expected), /must not traverse symlinks/);
  const parentAlias = path.join(temporary, 'parent-alias'); fs.symlinkSync(temporary, parentAlias);
  rejected('ancestor symlink', () => review.verifyArtifact(path.join(parentAlias, 'artifact'), expected), /must not traverse symlinks/);
  for (const [filename, size] of [['manifest.json', 64 * 1024 + 1], [FILES.baseline, MAX_ZIP + 1], [FILES.original, 4 * 1024 * 1024 + 1]]) {
    const target = path.join(directory, filename), saved = fs.readFileSync(target);
    fs.truncateSync(target, size);
    rejected(`oversized ${filename}`, () => review.verifyArtifact(directory, expected), /Artifact size limit/);
    fs.writeFileSync(target, saved);
  }
  const target = path.join(directory, 'manifest.json');
  for (const text of ['', '{broken', 'null', '[]']) {
    fs.writeFileSync(target, text);
    rejected(`invalid manifest JSON ${JSON.stringify(text)}`, () => review.verifyArtifact(directory, expected));
  }
  populate();
  check('CLI refusal emits no success JSON', () => {
    const result = spawnSync(process.execPath, [path.join(__dirname, 'engine-template-review.js'), directory,
      '--run', expected.run, '--sha', expected.sha], {encoding: 'utf8', timeout: 5000});
    assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.match(result.stderr, /^ENGINE_TEMPLATE_REVIEW: Actual original bytes differ/);
  });
  check('CLI exposes no ZIP reader/pin override', () => {
    const result = spawnSync(process.execPath, [path.join(__dirname, 'engine-template-review.js'), directory,
      '--run', expected.run, '--sha', expected.sha, '--readZip=unsafe'], {encoding: 'utf8', timeout: 5000});
    assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.match(result.stderr, /^ENGINE_TEMPLATE_REVIEW:/);
  });
} finally {
  // Only this test's exact, newly created temporary directory is removed.
  fs.rmSync(temporary, {recursive: true, force: true});
}
console.log(`ENGINE_TEMPLATE_REVIEW_CHECK: ${passed}/${passed} passed`);
