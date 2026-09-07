'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const gameSource = fs.readFileSync(path.join(root, 'game.js'), 'utf8');

const referencedIds = [...gameSource.matchAll(/\$\('#([^']+)'\)/g)].map((match) => match[1]);
for (const id of referencedIds) assert.match(html, new RegExp(`id=["']${id}["']`), `Missing #${id} in index.html`);
for (const file of ['styles.css', 'game.js']) assert.ok(fs.existsSync(path.join(root, file)), `Missing ${file}`);

function canvasContext() {
  const gradient = { addColorStop() {} };
  return new Proxy({}, {
    get(target, key) {
      if (key === 'createLinearGradient' || key === 'createRadialGradient') return () => gradient;
      if (!(key in target)) target[key] = () => {};
      return target[key];
    },
    set(target, key, value) { target[key] = value; return true; }
  });
}

function element(tag = 'div') {
  const listeners = {};
  const node = {
    tagName: tag.toUpperCase(), hidden: false, style: {}, className: '', innerHTML: '', textContent: '',
    width: tag === 'canvas' ? 220 : 0, height: tag === 'canvas' ? 170 : 0,
    classList: { add() {}, remove() {}, contains() { return false; } },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    dispatch(type, event = {}) { for (const fn of listeners[type] || []) fn(event); },
    setAttribute() {}, prepend() {}, remove() {},
    getContext() { return canvasContext(); },
    requestPointerLock() { document.pointerLockElement = node; for (const fn of documentListeners.pointerlockchange || []) fn(); }
  };
  return node;
}

const nodes = new Map();
const documentListeners = {};
const document = {
  pointerLockElement: null,
  querySelector(selector) {
    if (!nodes.has(selector)) nodes.set(selector, element(selector === '#game' || selector === '#minimap' ? 'canvas' : 'div'));
    return nodes.get(selector);
  },
  createElement(tag) { return element(tag); },
  addEventListener(type, fn) { (documentListeners[type] ||= []).push(fn); },
  exitPointerLock() { document.pointerLockElement = null; for (const fn of documentListeners.pointerlockchange || []) fn(); }
};

class AudioParam {
  setValueAtTime() {}
  exponentialRampToValueAtTime() {}
}
class AudioNode {
  constructor() { this.frequency = new AudioParam(); this.gain = new AudioParam(); }
  connect(target) { return target; }
  start() {}
  stop() {}
}
class AudioContext {
  constructor() { this.currentTime = 0; this.destination = new AudioNode(); }
  resume() {}
  createOscillator() { return new AudioNode(); }
  createGain() { return new AudioNode(); }
}

const animationFrames = [];
const sandbox = {
  console, document, innerWidth: 320, innerHeight: 180, performance,
  Math, Object, Array, Map, Set, Date,
  setTimeout: () => 0, clearTimeout() {},
  requestAnimationFrame(fn) { animationFrames.push(fn); },
  addEventListener() {}, devicePixelRatio: 1, AudioContext, URLSearchParams, location: { search: '' }
};
sandbox.window = sandbox;

vm.createContext(sandbox);
// Expose existing closure functions only inside this isolated test VM. The shipped
// game has no debug mutation API.
const instrumented = gameSource.replace('  resize(); resetBots();', `
  window.__rules = {
    player, shoot: playerShoot, objective: updateObjective, end: endRound,
    getBomb: () => bomb,
    prepare() { state = 'playing'; bots = []; keys = {}; money = 8000; ctScore = 0; tScore = 0; FOV = BASE_FOV; currentDefuser = null; Object.assign(player, {x:16.2,y:3.8,angle:Math.PI/2,pitch:0,health:100,armor:100,alive:true,weapon:'m4',ammo:30,mag:30,reserve:90,reloading:0,fireCooldown:0,recoil:0,sway:0,kills:0,deaths:0,defuse:0}); },
    target(team, y) { const bot = makeBot(team, 0, [16.2, y]); bots.push(bot); return bot; },
    plant(timer = 35) { bomb = {state:'planted',x:player.x,y:player.y,timer,site:'A'}; },
    defuse(held) { keys.KeyE = held; }
  };
  resize(); resetBots();`);
vm.runInContext(instrumented, sandbox, { filename: 'game.js' });
assert.ok(sandbox.DesertStrike, 'Public game diagnostics were not initialized');
assert.equal(sandbox.DesertStrike.version, '0.3.0');

const { map, sites, spawns } = sandbox.DesertStrike;
assert.equal(map.length, 24);
assert.ok(map.every((row) => row.length === 32));

const start = spawns.CT[0].map(Math.floor);
const queue = [start];
const visited = new Set([start.join(',')]);
for (let i = 0; i < queue.length; i++) {
  const [x, y] = queue[i];
  for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const nx = x + dx, ny = y + dy, key = `${nx},${ny}`;
    if (map[ny]?.[nx] === 0 && !visited.has(key)) { visited.add(key); queue.push([nx, ny]); }
  }
}
const floorCount = map.flat().filter((tile) => tile === 0).length;
assert.equal(visited.size, floorCount, 'Walkable map contains disconnected regions');
for (const [name, site] of Object.entries(sites)) assert.ok(visited.has(`${Math.floor(site.x)},${Math.floor(site.y)}`), `Site ${name} is unreachable`);
for (const [team, teamSpawns] of Object.entries(spawns)) {
  for (const spawn of teamSpawns) assert.ok(visited.has(spawn.map(Math.floor).join(',')), `${team} spawn ${spawn} is blocked`);
}

nodes.get('#play-button').dispatch('click');
for (const listener of documentListeners.keydown || []) listener({ code: 'KeyB' });
assert.equal(sandbox.DesertStrike.getState().state, 'buying', 'B did not open the buy menu');
for (const listener of documentListeners.keydown || []) listener({ code: 'Digit3' });
assert.equal(sandbox.DesertStrike.getState().weapon, 'awp', 'Weapon purchase did not equip the AWP');
assert.equal(sandbox.DesertStrike.getState().money, 3250, 'Weapon purchase did not deduct its price');
for (const listener of documentListeners.keydown || []) listener({ code: 'KeyB' });
for (const listener of documentListeners.mousemove || []) listener({ movementX: 0, movementY: -10 });
assert.ok(sandbox.DesertStrike.getState().playerPitch > 0, 'Moving the mouse up must move the projected horizon down');
for (let frame = 0; frame < 120; frame++) {
  const callback = animationFrames.shift();
  assert.ok(callback, 'Game loop stopped scheduling animation frames');
  callback(frame * 16.667);
}
const liveState = sandbox.DesertStrike.getState();
assert.equal(liveState.state, 'playing');
assert.equal(liveState.roundNumber, 1);
assert.ok(liveState.roundTime < 90, 'Round timer did not advance');

for (const listener of documentListeners.mousedown || []) listener({ button: 2 });
assert.equal(sandbox.DesertStrike.getState().aiming, true, 'Right click must aim');
for (const listener of documentListeners.mouseup || []) listener({ button: 2 });
assert.equal(sandbox.DesertStrike.getState().aiming, false);
for (const listener of documentListeners.mousedown || []) listener({ button: 0 });
assert.equal(sandbox.DesertStrike.getState().ammo, 9, 'AWP did not fire');
for (let frame = 120; frame < 210; frame++) animationFrames.shift()(frame * 16.667);
assert.equal(sandbox.DesertStrike.getState().ammo, 9, 'AWP must not repeat while the trigger is held');
for (const listener of documentListeners.mouseup || []) listener({ button: 0 });
document.exitPointerLock();
const beforePause = sandbox.DesertStrike.getState();
for (const listener of documentListeners.keydown || []) listener({ code: 'KeyR' });
for (let frame = 210; frame < 225; frame++) animationFrames.shift()(frame * 16.667);
assert.equal(sandbox.DesertStrike.getState().roundTime, beforePause.roundTime, 'Pause must freeze the simulation');
assert.equal(sandbox.DesertStrike.getState().reloading, 0, 'Reload must not start behind the pause menu');
nodes.get('#resume-button').dispatch('click');
assert.equal(sandbox.DesertStrike.getState().state, 'playing');

for (let frame = 225; frame < 6500; frame++) {
  const callback = animationFrames.shift();
  assert.ok(callback, 'Game loop stopped during a complete round simulation');
  callback(frame * 16.667);
}
const laterState = sandbox.DesertStrike.getState();
assert.ok(laterState.roundNumber >= 2, 'A complete round did not resolve and reset');
assert.ok(laterState.ctScore + laterState.tScore >= 1, 'Round resolution did not award a score');

const rules = sandbox.__rules;
rules.prepare();
let target = rules.target('T', 7.8);
rules.player.pitch = 180 / 4 * .82 / 6;
rules.shoot();
assert.equal(target.alive, false, 'Aimed headshots must kill, without a random headshot roll');
assert.equal(rules.player.kills, 1);
rules.prepare(); target = rules.target('T', 7.8); rules.shoot();
assert.ok(target.health > 50 && target.health < 80, 'Center-mass shots must do body damage');
rules.prepare(); target = rules.target('T', 7.8); rules.player.pitch = 63; rules.shoot();
assert.equal(target.health, 100, 'Shots above the target must miss');
rules.prepare(); const friend = rules.target('CT', 6.8); target = rules.target('T', 7.8); rules.shoot();
assert.equal(friend.health, 100, 'Friendly fire must be off');
assert.equal(target.health, 100, 'Friendly bodies must block bullets');
rules.prepare(); rules.plant(); rules.defuse(true); rules.objective(2);
assert.equal(rules.player.defuse, 2);
rules.defuse(false); rules.objective(.01);
assert.equal(rules.player.defuse, 0, 'Releasing E must reset the defuse');
rules.defuse(true); rules.objective(4.99); rules.getBomb().timer = .01; rules.objective(.02);
assert.equal(sandbox.DesertStrike.getState().tScore, 1, 'The bomb must win a simultaneous defuse/expiry');
rules.prepare();
for (let round = 0; round < 5; round++) {
  // Resume playing through the real round-start function via the frame loop.
  rules.end('CT', 'TEST');
  if (round < 4) for (let frame = 0; frame < 100; frame++) animationFrames.shift()(200000 + round * 10000 + frame * 50);
}
assert.equal(sandbox.DesertStrike.getState().state, 'matchover', 'First-to-five must end the match');
assert.equal(sandbox.DesertStrike.getState().ctScore, 5);

console.log(`Classic checks passed: ${referencedIds.length} DOM bindings, ${floorCount} connected tiles, 6,500 frames, aiming, semi-auto fire, pause, real headshots, occlusion, interrupted defuse, bomb expiry, and a first-to-five match.`);
