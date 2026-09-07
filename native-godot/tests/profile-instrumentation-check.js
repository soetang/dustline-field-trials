'use strict';

// Run with Node; only a tiny temporary GDScript fixture enters headless Godot.
// No renderer, full-project import, export, compiler, or normal-source mutation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { LABELS, SPECIFICATION, instrumentSource, instrumentProject } = require('./profile_instrumentation');

let checks = 0;
function check(fn) { fn(); checks++; }
const normal = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'courtyard-cpu-instrumentation-'));
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const normalHashes = new Map(SPECIFICATION.map(spec => [spec.file, hash(path.join(normal, spec.file))]));

const source = `extends RefCounted

# A fake signature inside documentation must not be selected.
const DOCUMENTATION = """
func typed(value: Unknown) -> Unknown:
    await invalid_fake_function()
"""
var seen: Array[int] = []

func typed(value: int = 7, note: String = "a,b:#()[]", points: Array[Vector3] = [Vector3(1, 2, 3), Vector3.ZERO]) -> Dictionary:
\t# await in a comment is not an async function.
\tif value < 0: return {"value": value, "note": note, "size": points.size()}
\tseen.append(value)
\treturn {"value": value, "note": note, "size": points.size()}

func void_fn(value: int = -1) -> void:
\tif value < 0: return
\tseen.append(value)

static func static_fn(
\t\tvalue: int = 3,
\t\tvalues: Array[int] = [2, 4], # default list contains a comma
\t\toptions: Dictionary = {"text": "a,b:#", "nest": [1, 2]},
\t\t) -> int:
\tif value == 0: return -10
\treturn value + values[0] + options.nest[1]

func nested(value: int) -> int:
\treturn static_fn(value) + int(typed(value).value)

func noargs() -> Array[Dictionary]:
\treturn [{"ok": true}, typed()]

func one_line(value: int = 2) -> int: return value + 1

func inferred(body := Transform3D.IDENTITY, height := Callable()) -> Vector3:
\treturn body.origin if not height.is_valid() else Vector3.UP

func object_identity(value: RefCounted = null) -> RefCounted:
\treturn value
`;
const scopes = ['typed', 'void_fn', 'static_fn', 'nested', 'noargs', 'one_line', 'inferred', 'object_identity'].map((name, id) => ({ name, id }));
const collector = `extends RefCounted
static var enabled := false
static var stack: Array[int] = []
static var events: Array[String] = []
static func begin(id: int) -> void:
\tstack.append(id)
\tevents.append("b%d" % id)
static func end() -> void:
\tevents.append("e%d" % stack.pop_back())
`;
const runner = `extends SceneTree
const Original = preload("res://original.gd")
const Wrapped = preload("res://wrapped.gd")
const Probe = preload("res://_cpu_profile.gd")
var failures := 0
func verify(ok: bool, label: String) -> void:
\tif not ok:
\t\tfailures += 1
\t\tprinterr("FAIL: ", label)
func exercise(script: GDScript) -> Dictionary:
\tvar subject = script.new()
\tvar override_points: Array[Vector3] = [Vector3.ONE]
\tvar identity := RefCounted.new()
\tvar values := [subject.typed(), subject.typed(-3, "override", override_points),
\t\tsubject.static_fn(), subject.static_fn(0), subject.nested(4),
\t\tsubject.noargs(), subject.one_line(), subject.inferred(),
\t\tsubject.object_identity() == null, subject.object_identity(identity) == identity]
\tsubject.void_fn()
\tsubject.void_fn(5)
\tsubject.void_fn(-2)
\treturn {"values": values, "seen": subject.seen.duplicate()}
func _initialize() -> void:
\tvar original := exercise(Original)
\tProbe.enabled = false
\tverify(exercise(Wrapped) == original, "disabled wrappers preserve values, defaults and mutations")
\tverify(Probe.events.is_empty() and Probe.stack.is_empty(), "disabled wrappers never enter collector")
\tProbe.enabled = true
\tverify(exercise(Wrapped) == original, "enabled typed/static/multiline/early-return wrappers preserve semantics")
\tverify(Probe.stack.is_empty(), "all early returns and nested calls close their scope")
\tvar events := ",".join(Probe.events)
\tverify(events.contains("b3,b2,e2,b0,e0,e3"), "nested wrapper IDs remain properly nested")
\tverify(events.contains("b1,e1,b1,e1,b1,e1"), "void early returns still end their scopes")
\tProbe.enabled = false
\tvar count := Probe.events.size()
\tverify(exercise(Wrapped) == original and Probe.events.size() == count, "disable after enabled run restores no-collector behavior")
\tprint("CPU_WRAPPER_SEMANTICS: ", "PASS" if failures == 0 else "FAIL")
\tquit(1 if failures else 0)
`;

function syntheticProject(destination) {
  fs.mkdirSync(path.join(destination, 'scripts'), { recursive: true });
  fs.writeFileSync(path.join(destination, 'project.godot'), '[application]\nconfig/name="CPU wrapper safety fixture"\n');
  fs.writeFileSync(path.join(destination, '_cpu_profile.gd'), collector);
  for (const file of new Set(SPECIFICATION.map(spec => spec.file))) {
    const functions = SPECIFICATION.filter(spec => spec.file === file)
      .map(spec => `func ${spec.name}(value: int = ${spec.id}) -> int:\n\treturn value\n`).join('\n');
    fs.writeFileSync(path.join(destination, file), `extends RefCounted\n\n${functions}`);
  }
}

try {
  check(() => assert.equal(LABELS.length, 23));
  check(() => assert.deepEqual(SPECIFICATION.map(spec => spec.id), Array.from({ length: 23 }, (_, i) => i)));
  check(() => assert.equal(LABELS[17], 'sound.play_at'));
  check(() => assert.equal(LABELS[19], 'spectator._physics_process'));
  check(() => assert.equal(LABELS[20], 'hud._draw'));
  check(() => assert.equal(LABELS[21], 'hud._draw_after_radar'));
  check(() => assert.equal(LABELS[22], 'hud._draw_static_radar'));
  const wrapped = instrumentSource(source, scopes);
  check(() => assert.equal((wrapped.match(/const CpuProbe = preload/g) || []).length, 1));
  check(() => assert.equal((wrapped.match(/CpuProbe.begin\(/g) || []).length, scopes.length));
  check(() => assert.match(wrapped, /static func _cpu_original_static_fn\(\n\t\tvalue: int = 3,/));
  check(() => assert.match(wrapped, /func _cpu_original_one_line\(value: int = 2\) -> int: return value \+ 1/));
  check(() => assert.match(wrapped, /var _cpu_profile_result: Array\[Dictionary\] = _cpu_original_noargs\(\)/));
  check(() => assert.match(wrapped, /var _cpu_profile_result: RefCounted = _cpu_original_object_identity\(value\)/));
  check(() => assert.match(wrapped, /func inferred\(body := Transform3D.IDENTITY, height := Callable\(\)\) -> Vector3:/));
  check(() => assert.doesNotMatch(wrapped, /return _cpu_original_void_fn\(/));
  check(() => assert.throws(() => instrumentSource(wrapped, scopes), /already instrumented/));
  check(() => assert.throws(() => instrumentSource(source, [{ name: 'missing', id: 0 }]), /exactly one/));
  check(() => assert.throws(() => instrumentSource(source, [{ name: 'typed', id: 33 }]), /invalid scope/));
  check(() => assert.throws(() => instrumentSource(source, [{ name: 'typed', id: 0 }, { name: 'void_fn', id: 0 }]), /duplicate scope/));
  const reject = (signature, body, expression) => check(() => assert.throws(
    () => instrumentSource(`extends RefCounted\n${signature}\n\t${body}\n`, [{ name: 'target', id: 0 }]), expression));
  reject('func target(value):', 'return value', /explicit return type/);
  reject('func target(...values) -> int:', 'return 1', /unsupported parameter/);
  reject('func target(value: Foo | Bar) -> int:', 'return 1', /unsupported parameter type/);
  reject('func target(value: int) -> Foo | Bar:', 'return null', /unsupported return type/);
  reject('func target(value: int) -> int:', 'await get_tree().process_frame', /async body unsupported/);
  reject('func target(value: int) -> int:', 'return super(value)', /implicit super unsupported/);
  reject('func target(_cpu_profile_result: int) -> int:', 'return 1', /reserved parameter/);
  reject('@rpc\nfunc target() -> void:', 'return', /annotated function unsupported/);
  check(() => assert.throws(() => instrumentSource('extends RefCounted\nconst BAD = "unterminated\n', scopes), /unterminated/));
  check(() => assert.throws(() => instrumentProject(normal), /refusing the normal project/));

  // Read-only preflight against every real selected scope. Normal source hashes
  // are checked again at the end; only synthetic/semantic copies are written.
  for (const file of new Set(SPECIFICATION.map(spec => spec.file))) {
    const selected = SPECIFICATION.filter(spec => spec.file === file);
    const transformed = instrumentSource(fs.readFileSync(path.join(normal, file), 'utf8'), selected);
    check(() => assert.equal((transformed.match(/CpuProbe.begin\(/g) || []).length, selected.length));
  }

  const complete = path.join(temporary, 'complete');
  syntheticProject(complete);
  const mapping = instrumentProject(complete);
  check(() => assert.deepEqual(mapping.mapping, SPECIFICATION));
  check(() => assert.deepEqual(mapping.labels, LABELS));
  check(() => assert.equal(mapping.files.length, 12));
  for (const spec of SPECIFICATION) check(() => assert.ok(fs.readFileSync(path.join(complete, spec.file), 'utf8').includes(`CpuProbe.begin(${spec.id})`)));

  const failClosed = path.join(temporary, 'fail-closed');
  syntheticProject(failClosed);
  fs.writeFileSync(path.join(failClosed, 'scripts/spectator.gd'), 'extends RefCounted\nfunc different() -> void:\n\tpass\n');
  const initial = new Map(mapping.files.map(file => [file, hash(path.join(failClosed, file))]));
  check(() => assert.throws(() => instrumentProject(failClosed), /exactly one _physics_process/));
  for (const [file, before] of initial) check(() => assert.equal(hash(path.join(failClosed, file)), before, 'failed preflight must not partially instrument files'));

  const linked = path.join(temporary, 'linked');
  syntheticProject(linked);
  const linkedTarget = path.join(linked, 'scripts/game.gd');
  fs.unlinkSync(linkedTarget);
  fs.symlinkSync(path.join(normal, 'scripts/game.gd'), linkedTarget);
  check(() => assert.throws(() => instrumentProject(linked), /unsafe copied source target/));
  fs.unlinkSync(linkedTarget);
  fs.linkSync(path.join(failClosed, 'scripts/game.gd'), linkedTarget);
  check(() => assert.throws(() => instrumentProject(linked), /unsafe copied source target/));
  const missingCollector = path.join(temporary, 'missing-collector');
  syntheticProject(missingCollector);
  fs.unlinkSync(path.join(missingCollector, '_cpu_profile.gd'));
  check(() => assert.throws(() => instrumentProject(missingCollector), /copy the test collector/));

  const semantics = path.join(temporary, 'semantics');
  fs.mkdirSync(semantics);
  fs.writeFileSync(path.join(semantics, 'project.godot'), '[application]\nconfig/name="CPU wrapper semantics"\n');
  fs.writeFileSync(path.join(semantics, '_cpu_profile.gd'), collector);
  fs.writeFileSync(path.join(semantics, 'original.gd'), source);
  fs.writeFileSync(path.join(semantics, 'wrapped.gd'), wrapped);
  fs.writeFileSync(path.join(semantics, 'check.gd'), runner);
  const godot = process.env.GODOT_BIN || path.resolve(normal, '../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64');
  const result = spawnSync(godot, ['--headless', '--path', semantics, '--script', 'res://check.gd'],
    { encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
  const output = (result.stdout || '') + (result.stderr || '');
  check(() => assert.equal(result.status, 0, output || String(result.error)));
  check(() => assert.doesNotMatch(output, /SCRIPT ERROR:|^ERROR:|^FAIL:/m));
  check(() => assert.match(output, /^CPU_WRAPPER_SEMANTICS: PASS$/m));
  for (const [file, before] of normalHashes) check(() => assert.equal(hash(path.join(normal, file)), before, 'normal project must remain unmodified'));
  console.log(`PROFILE_INSTRUMENTATION: ${checks}/${checks} passed; GDScript semantics verified headlessly`);
} catch (error) {
  console.error(`PROFILE_INSTRUMENTATION: FAIL after ${checks} checks`, error);
  process.exitCode = 1;
} finally {
  // This exact, newly-created OS-temp directory contains test fixtures only.
  fs.rmSync(temporary, { recursive: true, force: true });
}
