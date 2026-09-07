'use strict';

// Exercise the real Bash runner with disposable command shims; no Godot/GPU.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const baseline = [
  'verify|gd|VERIFICATION|60|test|-|tests',
  'tactics|gd|TACTICS|60|test|-|tactics',
  'aim|gd|AIM|60|test|-|aim',
  'encounters|gd|ENCOUNTERS|60|test|-|encounters',
  'query_reuse|gd|QUERY_REUSE|60|test|-|query-reuse',
  'room_lookup|gd|ROOM_LOOKUP|60|test|-|room-lookup',
  'navigation_clearance|gd|NAVIGATION_CLEARANCE|-|test|-|navigation-clearance',
  'bot_navigation|gd|BOT_NAVIGATION|60|test|-|bot-navigation',
  'cpu_profile_check|gd|CPU_PROFILE|-|test|-|cpu-profile',
  'shot_effects|gd|SHOT_EFFECTS|-|test|-|shot-effects',
  'profile-instrumentation|js|-|-|-|-|profile-instrumentation',
  'presentation-state-cache|js|-|-|-|-|presentation-state-cache',
  'gpu-timer-probe|js|-|-|-|-|gpu-timer-probe',
  'backbuffer-gl-audit|js|-|-|-|-|backbuffer-gl-audit',
  'ssao-unroll|js|-|-|-|-|ssao-unroll',
  'hud-buffer-probe|js|-|-|-|-|hud-buffer-probe',
  'compare-operator-reviews|js|-|-|-|-|operator-review-comparison',
  'hud_retention|gd|HUD_RETENTION|60|test|-|hud-retention',
  'flat_surface|gd|FLAT_SURFACE|-|-|-|flat-surface',
  'wall_collision|gd|WALL_COLLISION|60|test|-|wall-collision',
  'weapon_walls|gd|WEAPON_WALLS|60|test|-|weapon-walls',
  'operators|gd|OPERATORS|60|test|-|operators',
  'pose_reset|gd|POSE_RESET|-|test|-|pose-reset',
  'corpse_sleep|gd|CORPSE_SLEEP|-|test|-|corpse-sleep',
  'operator_surface|gd|OPERATOR_SURFACE|-|-|-|operator-surface',
  'feet|gd|FEET|60|test|-|feet',
  'map_update|gd|MAP_UPDATE|60|test|-|map',
  'material_batches|gd|MATERIAL_BATCHES|60|test|-|material-batches',
  'crate_mesh|gd|CRATE_MESH|-|-|20s|crate-mesh',
  'input|gd|INPUT|60|test|-|input',
  'combat|gd|COMBAT|60|test|-|combat',
  'audio|gd|AUDIO|60|test|-|audio',
  'rounds|gd|SEEDED_ROUNDS|60|test|-|rounds',
  'performance|gd|PERFORMANCE|60|test|-|performance',
  'reported_view|gd|REPORTED_VIEW|60|test|-|reported-view',
  'engine_map_dimensions|gd|ENGINE_MAP_DIMENSIONS|-|-|-|engine-map-dimensions',
  'reported-view|js|-|-|-|-|reported-view-input',
].map(row => {
  const [name, kind, sentinel, fps, testFlag, limit, log] = row.split('|');
  return {name, kind, sentinel, fps, testFlag, limit, log};
});
const fast = ['verify', 'aim', 'input', 'combat', 'pose_reset', 'corpse_sleep',
  'presentation-state-cache', 'gpu-timer-probe'];
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'courtyard-check-runner-'));
const project = path.join(temporary, 'project with spaces');
const bin = path.join(temporary, 'bin with spaces');
const runner = path.join(project, 'tools/check.sh');
const godot = path.join(bin, 'godot');
const callsFile = path.join(temporary, 'calls.jsonl');
let checks = 0;
function check(fn) { fn(); checks++; }

try {
  fs.mkdirSync(path.dirname(runner), {recursive: true});
  fs.mkdirSync(bin);
  fs.copyFileSync(path.resolve(__dirname, '../courtyard/tools/check.sh'), runner);
  const shim = '#!' + process.execPath + '\n' + `
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const args = process.argv.slice(2);
const tool = path.basename(process.argv[1]);
const script = args[args.indexOf('--script') + 1];
const name = tool === 'node' ? path.basename(args[0], '-check.js') :
  args.includes('--editor') ? 'import' : path.basename(script || '', '.gd');
fs.appendFileSync(process.env.MOCK_CALLS, JSON.stringify({tool, name, args, godot: process.env.GODOT_BIN}) + '\\n');
if (tool === 'timeout') {
  const child = spawnSync(args[1], args.slice(2), {stdio: 'inherit'});
  process.exit(child.status ?? 99);
}
const mode = name === process.env.MOCK_TARGET ? process.env.MOCK_FAILURE : '';
if (mode === 'nonzero') process.exit(7);
if (mode === 'script_error') console.log('SCRIPT ERROR: deliberate fixture error despite exit zero');
if (mode === 'error') console.log('ERROR: deliberate fixture error despite exit zero');
if (mode === 'fail') console.log('FAIL: deliberate fixture failure despite success sentinel');
if (mode === 'missing') { console.log('UNRELATED: 1/1 passed'); process.exit(0); }
const labels = JSON.parse(process.env.MOCK_LABELS);
if (name !== 'import') console.log((labels[name] || 'NODE_FIXTURE') + ': 1/1 passed');
`;
  for (const tool of ['godot', 'node', 'timeout']) {
    fs.writeFileSync(path.join(bin, tool), shim, {mode: 0o755});
  }

  function run(args, target = '', failure = '', extra = {}) {
    fs.writeFileSync(callsFile, '');
    const result = spawnSync('bash', [runner, ...args], {
      encoding: 'utf8', timeout: 15000,
      env: {...process.env, PATH: bin + path.delimiter + process.env.PATH,
        GODOT_BIN: godot, MOCK_CALLS: callsFile, MOCK_TARGET: target, MOCK_FAILURE: failure,
        MOCK_LABELS: JSON.stringify(Object.fromEntries(baseline.map(row => [row.name, row.sentinel]))), ...extra}
    });
    assert.ifError(result.error);
    result.calls = fs.readFileSync(callsFile, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
    return result;
  }

  function expectSelection(result, names) {
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const calls = result.calls.filter(call => call.tool !== 'timeout');
    assert.deepEqual(calls.map(call => call.name), ['import', ...names]);
    assert.deepEqual(calls[0].args, ['--headless', '--path', project, '--editor', '--import']);
    assert.equal(calls.filter(call => call.name === 'import').length, 1);
    for (const [index, name] of names.entries()) {
      const spec = baseline.find(row => row.name === name);
      const call = calls[index + 1];
      if (spec.kind === 'js') {
        assert.equal(call.tool, 'node');
        assert.deepEqual(call.args, [path.join(project, 'tests', name + '-check.js')]);
        assert.equal(call.godot, godot);
      } else {
        const args = ['--headless', '--path', project];
        if (spec.fps !== '-') args.push('--fixed-fps', spec.fps);
        args.push('--script', 'res://tests/' + name + '.gd');
        if (spec.testFlag === 'test') args.push('--', '--test');
        assert.equal(call.tool, 'godot');
        assert.deepEqual(call.args, args);
        if (spec.limit !== '-') {
          assert.ok(result.calls.some(event => event.tool === 'timeout' &&
            JSON.stringify(event.args) === JSON.stringify([spec.limit, godot, ...args])));
        }
      }
    }
    assert.equal(result.calls.filter(call => call.tool === 'timeout').length,
      names.filter(name => baseline.find(row => row.name === name).limit !== '-').length);
  }

  check(() => {
    const result = run(['--list'], '', '', {GODOT_BIN: '/nonexistent/godot'});
    assert.equal(result.status, 0);
    assert.deepEqual(result.stdout.trim().split('\n'), baseline.map(row => row.name));
    assert.deepEqual(result.calls, []);
  });
  check(() => expectSelection(run([]), baseline.map(row => row.name)));
  check(() => expectSelection(run(['--fast']), fast));
  check(() => expectSelection(run(['pose_reset', 'weapon_walls']), ['pose_reset', 'weapon_walls']));
  check(() => expectSelection(run(['compare-operator-reviews', 'crate_mesh']), ['compare-operator-reviews', 'crate_mesh']));
  check(() => expectSelection(run(['reported_view', 'reported-view']), ['reported_view', 'reported-view']));
  for (const args of [['unknown'], ['aim', 'unknown'], ['--fast', 'aim'], ['--list', 'aim']]) {
    check(() => {
      const result = run(args);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Unknown suite/);
      assert.deepEqual(result.calls, []);
    });
  }
  check(() => {
    const result = run(['aim'], '', '', {GODOT_BIN: '/nonexistent/godot'});
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Install Godot first/);
    assert.deepEqual(result.calls, []);
  });
  for (const mode of ['nonzero', 'script_error', 'error']) {
    check(() => {
      const result = run(['aim'], 'import', mode);
      assert.notEqual(result.status, 0, mode);
      assert.deepEqual(result.calls.map(call => call.name), ['import']);
    });
  }
  for (const mode of ['nonzero', 'script_error', 'error', 'fail', 'missing']) {
    check(() => {
      const result = run(['aim', 'combat'], 'aim', mode);
      assert.notEqual(result.status, 0, mode);
      assert.deepEqual(result.calls.map(call => call.name), ['import', 'aim']);
      if (mode === 'missing') assert.match(result.stderr, /Missing success sentinel for aim/);
    });
  }
  check(() => {
    const result = run(['gpu-timer-probe', 'aim'], 'gpu-timer-probe', 'nonzero');
    assert.notEqual(result.status, 0);
    assert.deepEqual(result.calls.map(call => call.name), ['import', 'gpu-timer-probe']);
  });
  check(() => {
    const result = run(['crate_mesh', 'aim'], 'crate_mesh', 'nonzero');
    assert.notEqual(result.status, 0);
    assert.deepEqual(result.calls.map(call => call.tool), ['godot', 'timeout', 'godot']);
  });
  check(() => {
    const result = run(['reported_view', 'reported-view'], 'reported_view', 'missing');
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Missing success sentinel for reported_view/);
    assert.deepEqual(result.calls.map(call => call.name), ['import', 'reported_view']);
  });
  check(() => {
    const result = run(['reported-view', 'reported_view'], 'reported-view', 'nonzero');
    assert.notEqual(result.status, 0);
    assert.deepEqual(result.calls.map(call => call.name), ['import', 'reported-view']);
  });
  console.log(`CHECK_RUNNER: ${checks}/${checks} passed; ${baseline.length} default suites/flags, targeted/fast selection, import/error/sentinel/exit checks; no Godot or GPU`);
} finally {
  fs.rmSync(temporary, {recursive: true, force: true});
}
