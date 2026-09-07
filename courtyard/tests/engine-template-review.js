'use strict';

// Offline consistency/provenance-pin check, not compiler attestation. The caller
// must independently authenticate the successful GitHub workflow/run/head SHA.
// Nothing is extracted, downloaded, executed, installed, rendered or deployed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');

const PINS = Object.freeze({
  tag: '4.7.2-stable', revision: 'ed1daf0bf001b61586d9930840f2f1394092c079',
  url: 'https://codeload.github.com/godotengine/godot/tar.gz/refs/tags/4.7.2-stable',
  archive_sha256: 'e954996374cbd1cb5d72e0e3781cc537408e6ce73b010b12c6c2f308a820690a',
  original_cpp_sha256: '6d0719c9cd2caf685a9825028183bdf058081d7bc92d4b27ed2587f39b081221',
  patched_cpp_sha256: 'b09e9085788b45d9d3b8dab6052a1b1e9fc3132f713b90f613fcd010437717d4',
  patch_sha256: 'beae0eea522dde438af7415393c0fe77f25486e7accf2a341658485ce1ec96cd',
  emsdk_revision: '5eb0bde7585670252e8ba05e9d361627bffd08b5', emscripten: '4.0.20',
  emscripten_revision: 'c387d7a7e9537d0041d2c3ae71b7538cc978104e', scons: '4.9.1',
});
const FILES = Object.freeze({baseline: 'baseline-web-nothreads.zip', patched: 'remove-ssao-depth-copy-web-nothreads.zip',
  original: 'source-original.cpp', candidate: 'source-patched.cpp', patch: 'remove-ssao-depth-copy.patch'});
const ZIP_NAMES = Object.freeze(['godot.js', 'godot.wasm', 'godot.audio.worklet.js',
  'godot.audio.position.worklet.js', 'godot.html', 'godot.service.worker.js', 'godot.offline.html']);
const MAX_ZIP = 100 * 1024 * 1024;
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const exactKeys = (value, keys, label) => {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label}: expected object`);
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort(), `${label}: unexpected/missing fields`);
};
const digest = value => assert.match(value, /^[a-f0-9]{64}$/, 'Expected lowercase SHA256');

function expectations(value) {
  assert.ok(value && typeof value.run === 'string' && /^[1-9][0-9]{0,19}$/.test(value.run), 'Expected positive decimal --run ID');
  assert.ok(typeof value.sha === 'string' && /^[a-f0-9]{40}$/.test(value.sha), 'Expected full lowercase --sha commit');
}

function validateManifest(input, expected) {
  expectations(expected);
  exactKeys(input, ['repository_revision', 'workflow_run', 'source', 'patch', 'toolchain',
    'flags', 'pythonhashseed', 'order', 'templates', 'limitations'], 'manifest');
  assert.equal(input.workflow_run, expected.run, 'Wrong workflow run');
  assert.equal(input.repository_revision, expected.sha, 'Wrong repository head SHA');
  const sourceKeys = ['tag', 'revision', 'url', 'archive_sha256', 'original_cpp_sha256', 'patched_cpp_sha256'];
  assert.deepEqual(input.source, Object.fromEntries(sourceKeys.map(key => [key, PINS[key]])), 'Pinned original source/revision differs');
  assert.deepEqual(input.patch, {file: FILES.patch, sha256: PINS.patch_sha256}, 'Only the pinned SSAO depth-copy patch is allowed');
  const toolKeys = ['emsdk_revision', 'emscripten', 'emscripten_revision', 'scons'];
  exactKeys(input.toolchain, [...toolKeys, 'compiler_version', 'python', 'node'], 'toolchain');
  for (const key of toolKeys) assert.equal(input.toolchain[key], PINS[key], `Pinned toolchain ${key} differs`);
  for (const key of ['compiler_version', 'python', 'node'])
    assert.ok(typeof input.toolchain[key] === 'string' && input.toolchain[key].length > 0 && input.toolchain[key].length <= 8192 && !input.toolchain[key].includes('\0'), `Invalid ${key} version text`);
  assert.match(input.toolchain.compiler_version, /^emcc [^\r\n]* 4\.0\.20(?:\s|$)/, 'Wrong compiler banner');
  assert.match(input.toolchain.python, /^Python 3\.12\.\d+$/, 'Expected workflow Python 3.12');
  // The pinned SDK prepends its own Node; setup-node's version is not necessarily
  // the executable used after emsdk_env.sh. Preserve/check its recorded syntax.
  assert.match(input.toolchain.node, /^v\d+\.\d+\.\d+$/, 'Invalid Node version');
  assert.ok(Array.isArray(input.flags) && ['-j2', '-j4'].includes(input.flags[4]), 'Expected reviewed jobs 2 or 4');
  assert.deepEqual(input.flags, ['platform=web', 'target=template_release', 'threads=no', 'production=yes', input.flags[4]], 'Build flags must be identical pinned release flags');
  assert.equal(input.pythonhashseed, 0, 'Expected deterministic Python hash seed');
  assert.equal(input.order, 'baseline, then only the patch; same incremental build directory', 'Wrong build order');
  assert.ok(typeof input.limitations === 'string' && input.limitations.length > 0 && input.limitations.length <= 4096, 'Missing bounded limitations text');
  assert.ok(Array.isArray(input.templates) && input.templates.length === 2, 'Exactly two matched templates required');
  for (const [index, name, zip] of [[0, 'baseline', FILES.baseline], [1, 'remove-ssao-depth-copy', FILES.patched]]) {
    const entry = input.templates[index];
    exactKeys(entry, ['name', 'zip', 'zip_sha256', 'js_sha256', 'wasm_sha256'], 'template');
    assert.equal(entry.name, name, 'Fixed template order/name');
    assert.equal(entry.zip, zip, 'Fixed template filename; no manifest paths');
    for (const key of ['zip_sha256', 'js_sha256', 'wasm_sha256']) digest(entry[key]);
  }
  assert.notEqual(input.templates[0].wasm_sha256, input.templates[1].wasm_sha256, 'Patched Wasm must differ from baseline');
  return JSON.parse(JSON.stringify(input)); // Detached from module caller's input.
}

const crcTable = Uint32Array.from({length: 256}, (_, byte) => {
  for (let bit = 0; bit < 8; bit++) byte = (byte >>> 1) ^ ((byte & 1) ? 0xedb88320 : 0);
  return byte >>> 0;
});
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function readTemplateZip(bytes) {
  assert.ok(Buffer.isBuffer(bytes) && bytes.length >= 22 && bytes.length <= MAX_ZIP, 'Bounded ZIP buffer required');
  let end = -1;
  for (let at = bytes.length - 22; at >= Math.max(0, bytes.length - 65557); at--) {
    if (bytes.readUInt32LE(at) === 0x06054b50 && at + 22 + bytes.readUInt16LE(at + 20) === bytes.length) { end = at; break; }
  }
  assert.ok(end >= 0, 'Missing ZIP end record or trailing data');
  assert.equal(bytes.readUInt16LE(end + 4), 0, 'Multi-disk ZIP unsupported');
  assert.equal(bytes.readUInt16LE(end + 6), 0, 'Multi-disk ZIP unsupported');
  const count = bytes.readUInt16LE(end + 10), size = bytes.readUInt32LE(end + 12), start = bytes.readUInt32LE(end + 16);
  assert.equal(count, ZIP_NAMES.length, 'Exactly seven pinned Godot ZIP entries required');
  assert.equal(bytes.readUInt16LE(end + 8), count, 'Split ZIP entries unsupported');
  assert.equal(start + size, end, 'ZIP central-directory bounds/ZIP64 unsupported');
  const result = new Map(), ranges = [];
  let at = start, total = 0;
  const bounded = (offset, length, limit = bytes.length) => assert.ok(Number.isSafeInteger(offset) && offset >= 0 && offset + length <= limit, 'Truncated/overlapping ZIP structure');
  for (let index = 0; index < count; index++) {
    bounded(at, 46, end);
    assert.equal(bytes.readUInt32LE(at), 0x02014b50, 'Bad central ZIP header');
    assert.ok(bytes.readUInt16LE(at + 6) <= 20, 'ZIP64/new ZIP features unsupported');
    const flags = bytes.readUInt16LE(at + 8), method = bytes.readUInt16LE(at + 10), crc = bytes.readUInt32LE(at + 16);
    assert.equal(flags & ~(0x800 | 8 | 6), 0, 'Encrypted/unsupported ZIP flags');
    assert.ok(method === 0 || method === 8, 'Only stored/deflated ZIP entries supported');
    const compressed = bytes.readUInt32LE(at + 20), length = bytes.readUInt32LE(at + 24);
    const nameLength = bytes.readUInt16LE(at + 28), extra = bytes.readUInt16LE(at + 30), comment = bytes.readUInt16LE(at + 32);
    assert.equal(bytes.readUInt16LE(at + 34), 0, 'Split ZIP member unsupported');
    const attributes = bytes.readUInt32LE(at + 38), type = (attributes >>> 16) & 0xf000;
    assert.ok((type === 0 || type === 0x8000) && !(attributes & 16), 'ZIP symlink/directory/special member rejected');
    const offset = bytes.readUInt32LE(at + 42);
    bounded(at + 46, nameLength + extra + comment, end);
    const nameBytes = bytes.subarray(at + 46, at + 46 + nameLength), name = nameBytes.toString('utf8');
    assert.ok(ZIP_NAMES.includes(name) && Buffer.from(name).equals(nameBytes) && !result.has(name), 'Unsafe/unexpected/duplicate ZIP member name');
    total += length;
    assert.ok(length > 0 && compressed > 0 && total <= MAX_ZIP, 'ZIP expanded-size limit');
    bounded(offset, 30, start);
    assert.equal(bytes.readUInt32LE(offset), 0x04034b50, 'Bad local ZIP header');
    assert.ok(bytes.readUInt16LE(offset + 4) <= 20, 'ZIP64 local header unsupported');
    assert.equal(bytes.readUInt16LE(offset + 6), flags, 'Local/central ZIP flags mismatch');
    assert.equal(bytes.readUInt16LE(offset + 8), method, 'Local/central ZIP method mismatch');
    const localNameLength = bytes.readUInt16LE(offset + 26), localExtra = bytes.readUInt16LE(offset + 28);
    bounded(offset + 30, localNameLength + localExtra, start);
    assert.ok(bytes.subarray(offset + 30, offset + 30 + localNameLength).equals(nameBytes), 'Local/central ZIP name mismatch');
    const dataStart = offset + 30 + localNameLength + localExtra;
    bounded(dataStart, compressed, start);
    let dataEnd = dataStart + compressed;
    for (const [delta, expected] of [[14, crc], [18, compressed], [22, length]]) {
      const local = bytes.readUInt32LE(offset + delta);
      assert.ok(local === expected || ((flags & 8) && local === 0), 'Local/central ZIP sizes/CRC mismatch');
    }
    if (flags & 8) {
      bounded(dataEnd, 12, start);
      if (bytes.readUInt32LE(dataEnd) === 0x08074b50) { dataEnd += 4; bounded(dataEnd, 12, start); }
      assert.equal(bytes.readUInt32LE(dataEnd), crc, 'ZIP descriptor CRC mismatch');
      assert.equal(bytes.readUInt32LE(dataEnd + 4), compressed, 'ZIP descriptor size mismatch');
      assert.equal(bytes.readUInt32LE(dataEnd + 8), length, 'ZIP descriptor size mismatch');
      dataEnd += 12;
    }
    const data = bytes.subarray(dataStart, dataStart + compressed);
    const decoded = method === 0 ? data : zlib.inflateRawSync(data, {maxOutputLength: length});
    assert.equal(decoded.length, length, 'ZIP decoded size mismatch');
    assert.equal(crc32(decoded), crc, 'ZIP CRC mismatch');
    result.set(name, decoded);
    ranges.push([offset, dataEnd]);
    at += 46 + nameLength + extra + comment;
  }
  assert.equal(at, end, 'Unexpected central ZIP data');
  ranges.sort((a, b) => a[0] - b[0]);
  let next = 0;
  for (const range of ranges) { assert.equal(range[0], next, 'Overlapping/noncontiguous ZIP members'); next = range[1]; }
  assert.equal(next, start, 'Unexpected ZIP prefix/gap');
  return result;
}

function verifyTemplates(manifest, archives, readZip = readTemplateZip) {
  const output = {};
  for (const [index, key] of ['baseline', 'patched'].entries()) {
    const bytes = archives[key], expected = manifest.templates[index];
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= MAX_ZIP, 'Bounded archive bytes required');
    assert.equal(hash(bytes), expected.zip_sha256, `${key} ZIP hash mismatch`);
    // Dependency injection is only for trusted in-process unit tests. CLI always
    // uses the complete bounded ZIP parser above; no reader/pin override flags.
    const files = readZip(bytes);
    assert.ok(files instanceof Map, 'ZIP reader must return a Map');
    assert.deepEqual([...files.keys()].sort(), [...ZIP_NAMES].sort(), 'Exact ZIP member inventory required');
    let expanded = 0;
    for (const data of files.values()) {
      assert.ok(Buffer.isBuffer(data) && data.length > 0, 'ZIP member bytes required');
      expanded += data.length;
    }
    assert.ok(expanded <= MAX_ZIP, 'ZIP expanded-size limit');
    const js = hash(files.get('godot.js')), wasm = hash(files.get('godot.wasm'));
    assert.equal(js, expected.js_sha256, `${key} embedded JS hash mismatch`);
    assert.equal(wasm, expected.wasm_sha256, `${key} embedded Wasm hash mismatch`);
    assert.ok(files.get('godot.wasm').subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])), 'Expected WebAssembly v1 member');
    output[key] = {zip_sha256: hash(bytes), js_sha256: js, wasm_sha256: wasm};
  }
  assert.notEqual(output.baseline.wasm_sha256, output.patched.wasm_sha256, 'Patched Wasm must actually differ');
  return output;
}

function readRegular(directory, name, maximum) {
  const filename = path.join(directory, name), initial = fs.lstatSync(filename);
  assert.ok(initial.isFile() && !initial.isSymbolicLink() && initial.nlink === 1, `Regular unlinked artifact file required: ${name}`);
  assert.ok(initial.size > 0 && initial.size <= maximum, `Artifact size limit: ${name}`);
  const fd = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const opened = fs.fstatSync(fd);
    assert.ok(opened.isFile() && opened.dev === initial.dev && opened.ino === initial.ino && opened.size === initial.size, 'Artifact changed while opening');
    const bytes = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < bytes.length) {
      const count = fs.readSync(fd, bytes, offset, bytes.length - offset, offset);
      assert.ok(count > 0, 'Truncated artifact file'); offset += count;
    }
    const after = fs.fstatSync(fd);
    assert.ok(after.size === opened.size && after.mtimeMs === opened.mtimeMs && after.ctimeMs === opened.ctimeMs, 'Artifact changed while reading');
    return bytes;
  } finally { fs.closeSync(fd); }
}

function verifyArtifact(directory, expected, options = {}) {
  expectations(expected);
  assert.ok(typeof directory === 'string' && directory.length > 0 && !directory.includes('\0'), 'Expected artifact directory');
  const root = path.resolve(directory), stat = fs.lstatSync(root);
  assert.ok(stat.isDirectory() && !stat.isSymbolicLink() && fs.realpathSync(root) === root, 'Artifact directory must not traverse symlinks');
  const manifest = validateManifest(JSON.parse(readRegular(root, 'manifest.json', 64 * 1024)), expected);
  const bytes = Object.fromEntries(Object.entries(FILES).map(([key, file]) =>
    [key, readRegular(root, file, ['baseline', 'patched'].includes(key) ? MAX_ZIP : 4 * 1024 * 1024)]));
  for (const [key, pin] of [['original', PINS.original_cpp_sha256], ['candidate', PINS.patched_cpp_sha256], ['patch', PINS.patch_sha256]])
    assert.equal(hash(bytes[key]), pin, `Actual ${key} bytes differ from the reviewed pin (manifest hashes alone are not proof)`);
  const templates = verifyTemplates(manifest, bytes, options.readZip);
  for (const key of ['baseline', 'patched']) templates[key] = {path: path.join(root, FILES[key]), ...templates[key]};
  return {schema: 1, workflow_run: expected.run, repository_revision: expected.sha, artifact_dir: root,
    flags: manifest.flags, templates};
}

function parseArguments(args) {
  let directory;
  const expected = {};
  for (let index = 0; index < args.length; index++) {
    const argument = args[index], match = /^--(run|sha)(?:=(.*))?$/.exec(argument);
    if (match) {
      assert.equal(expected[match[1]], undefined, `Duplicate --${match[1]}`);
      expected[match[1]] = match[2] === undefined ? args[++index] : match[2];
    } else {
      assert.ok(!argument.startsWith('-') && directory === undefined, 'Usage: engine-template-review.js DIRECTORY --run ID --sha FULL_SHA');
      directory = argument;
    }
  }
  expectations(expected);
  assert.ok(directory, 'Missing artifact directory');
  return {directory, expected};
}

module.exports = {PINS, FILES, ZIP_NAMES, MAX_ZIP, validateManifest, readTemplateZip, verifyTemplates, verifyArtifact, parseArguments};
if (require.main === module) {
  try {
    const {directory, expected} = parseArguments(process.argv.slice(2));
    process.stdout.write(JSON.stringify(verifyArtifact(directory, expected), null, 2) + '\n');
  } catch (error) { console.error(`ENGINE_TEMPLATE_REVIEW: ${error.message}`); process.exitCode = 1; }
}
