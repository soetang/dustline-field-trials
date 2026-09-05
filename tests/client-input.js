'use strict';
// Fast browser-to-Rust input/HUD contract checks; no GPU or browser process needed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'bevy.html'), 'utf8');

function eventTarget() {
  const listeners = {};
  return {
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    dispatchEvent(event) {
      event.target ||= this; event.preventDefault ||= () => {};
      return Promise.all((listeners[event.type] || []).map(fn => fn(event)));
    },
  };
}
function element(tag = 'div') {
  const classes = new Set();
  return Object.assign(eventTarget(), {
    tagName: tag.toUpperCase(), hidden: false, value: '', textContent: '', dataset: {},
    style: { setProperty() {} }, width: 224, height: 168,
    classList: { add(v) { classes.add(v); }, remove(v) { classes.delete(v); }, contains(v) { return classes.has(v); }, toggle(v, active) { if (active) classes.add(v); else classes.delete(v); } },
    setAttribute() {}, remove() {}, focus() { document.activeElement = this; }, select() { this.selected = true; },
    replaceChildren(...children) { this.children = children; }, append(...children) { (this.children ||= []).push(...children); },
    getContext() { return new Proxy({}, { get(target, key) { return target[key] ?? (() => {}); } }); },
  });
}
const nodes = new Map([...html.matchAll(/<([a-z][a-z0-9]*)\b[^>]*\bid="([^"]+)"[^>]*>/g)].map(([markup, tag, id]) => {
  const node = element(tag); node.id = id; node.hidden = /\bhidden\b/.test(markup); return [id, node];
}));
const cards = [0, 1, 2, 3].map(slot => Object.assign(element('button'), {dataset: {slot: String(slot)}}));
const document = Object.assign(eventTarget(), {
  hidden: false, pointerLockElement: null, body: element('body'),
  getElementById(id) { assert.ok(nodes.has(id), `Unknown HUD ID ${id}`); return nodes.get(id); },
  querySelectorAll(selector) { assert.equal(selector, '[data-slot]'); return cards; },
  createElement: element,
  exitPointerLock() { this.pointerLockElement = null; this.dispatchEvent({type: 'pointerlockchange'}); },
});
const canvas = nodes.get('bevy-canvas');
canvas.requestPointerLock = async () => { document.pointerLockElement = canvas; await document.dispatchEvent({type: 'pointerlockchange'}); };
const window = eventTarget();
const sandbox = {window, document, console, structuredClone, navigator: {userAgent: 'Fast contract test'},
  localStorage: {getItem() { return null; }, setItem() {}}, location: {origin: 'http://localhost', pathname: '/bevy.html'},
  Event: class { constructor(type) { this.type = type; } }, performance: {now: () => 0}};
vm.runInNewContext(fs.readFileSync(path.join(root, 'client.js'), 'utf8'), sandbox, {filename: 'client.js'});
const api = window.desertStrike;
const input = () => JSON.parse(JSON.stringify(api.input()));
const state = require('./client-state')();
const key = (type, code, extra = {}) => document.dispatchEvent({type, code, target: canvas, repeat: false, ...extra});
const click = id => nodes.get(id).dispatchEvent({type: 'click'});

(async () => {
  assert.equal(input().active, false);
  assert.equal(input().quality, 'standard');
  assert.ok(Number.isInteger(input().seed) && input().seed > 0);
  nodes.get('quality').value = 'low'; await nodes.get('quality').dispatchEvent({type: 'change'});
  assert.equal(input().quality, 'low');
  nodes.get('quality').value = 'standard'; await nodes.get('quality').dispatchEvent({type: 'change'});
  api.render(state);
  assert.equal(nodes.get('score-rows').children[1].children[1].textContent, 'HOLDING');
  assert.equal(nodes.get('score-rows').children[5].children[1].textContent, 'ACTIVE', 'Enemy intentions must not leak onto the scoreboard');
  api.render({...state, bots: state.bots.map((bot, i) => i === 0 ? {...bot, intent: 'COVERING SITE'} : bot)});
  assert.equal(nodes.get('score-rows').children[1].children[1].textContent, 'COVERING SITE');
  api.render(state);
  assert.equal(nodes.get('front-menu').hidden, false);
  assert.equal(nodes.get('location').textContent, 'CT SPAWN');
  assert.ok(cards.every(card => !card.disabled), 'Expanded spawn did not enable the armory');
  await click('deploy');
  let controls = input(); assert.equal(controls.active, true); assert.deepEqual(controls.commands, ['start']);
  assert.deepEqual(input().commands, [], 'Deployment command was replayed');

  await key('keydown', 'KeyW'); await key('keydown', 'KeyA');
  await document.dispatchEvent({type: 'mousemove', movementX: 12, movementY: -8});
  await document.dispatchEvent({type: 'mousemove', movementX: 5, movementY: 3});
  await document.dispatchEvent({type: 'mousedown', button: 0});
  controls = input(); assert.equal(controls.held.KeyW, true); assert.equal(controls.held.KeyA, true);
  assert.equal(controls.lookX, 17); assert.equal(controls.lookY, -5); assert.equal(controls.firePressed, true);
  controls = input(); assert.equal(controls.lookX, 0); assert.equal(controls.firePressed, false); assert.equal(controls.held.fire, true);
  await key('keyup', 'KeyW'); await key('keyup', 'KeyA'); await document.dispatchEvent({type: 'mouseup', button: 0});
  controls = input(); assert.equal(controls.held.KeyW, false); assert.equal(controls.held.fire, false);
  await key('keydown', 'KeyR'); assert.equal(input().reloadPressed, true);
  await key('keydown', 'KeyR', {repeat: true}); assert.equal(input().reloadPressed, false);
  await key('keyup', 'KeyR');
  await document.dispatchEvent({type: 'mousedown', button: 2}); assert.equal(input().held.aim, true);
  await document.dispatchEvent({type: 'mouseup', button: 2}); assert.equal(input().held.aim, false);
  await key('keydown', 'Tab'); assert.equal(nodes.get('scoreboard').hidden, false);
  await key('keyup', 'Tab'); assert.equal(nodes.get('scoreboard').hidden, true);

  await key('keydown', 'KeyW'); await document.dispatchEvent({type: 'mousedown', button: 0});
  await key('keydown', 'KeyB'); controls = input(); assert.equal(controls.shop, true); assert.deepEqual(controls.held, {}); assert.equal(nodes.get('buy-menu').hidden, false);
  await cards[2].dispatchEvent({type: 'click'}); assert.deepEqual(input().commands, ['buy2']);
  await key('keydown', 'Digit1'); assert.deepEqual(input().commands, ['buy0']);
  await key('keydown', 'Digit1', {repeat: true}); assert.deepEqual(input().commands, []);
  api.render({...state, x: 48}); assert.ok(cards.every(card => card.disabled), 'Buy controls enabled outside spawn');
  await cards[0].dispatchEvent({type: 'click'}); assert.deepEqual(input().commands, []);
  api.render(state); await click('close-buy'); controls = input(); assert.equal(controls.active, true); assert.deepEqual(controls.held, {}, 'Armory retained held movement/fire after recapture');
  api.render({...state, health: 0}); await key('keydown', 'KeyC'); assert.deepEqual(input().commands, ['spectate']);
  await key('keydown', 'KeyC', {repeat: true}); assert.deepEqual(input().commands, []); api.render(state);

  await key('keydown', 'KeyW'); await document.dispatchEvent({type: 'mousedown', button: 0});
  document.exitPointerLock();
  controls = input(); assert.equal(controls.active, false); assert.deepEqual(controls.held, {}); assert.equal(controls.firePressed, false);
  await key('keydown', 'KeyW'); await document.dispatchEvent({type: 'mousedown', button: 0});
  controls = input(); assert.deepEqual(controls.held, {}); assert.equal(controls.firePressed, false);
  api.release = './web/builds/release-test/desert_strike.js';
  await click('copy-feedback');
  assert.match(nodes.get('test-details').value, /64 × 48 metres/);
  assert.match(nodes.get('test-details').value, /release-test/);
  assert.match(nodes.get('test-details').value, /View: yaw 179\.9°; pitch 5\.7°; ground 0\.00m; aiming no/);
  assert.equal(nodes.get('test-details').selected, true, 'Clipboard-unavailable fallback must select the report');
  await click('resume'); assert.equal(input().active, true);
  await key('keydown', 'KeyW'); await document.dispatchEvent({type: 'mousedown', button: 0});
  await key('keydown', 'F8');
  assert.equal(input().active, false); assert.deepEqual(input().held, {});
  assert.equal(document.pointerLockElement, null);
  assert.equal(document.body.classList.contains('screenshot-view'), true);
  assert.equal(nodes.get('pause').hidden, true); assert.equal(nodes.get('screenshot-exit').hidden, false);
  assert.equal(document.activeElement, nodes.get('screenshot-exit'));
  await window.dispatchEvent({type: 'blur'});
  document.hidden = true; await document.dispatchEvent({type: 'visibilitychange'});
  assert.equal(nodes.get('pause').hidden, true, 'OS screenshot tool must not reveal the pause overlay');
  assert.equal(input().active, false);
  document.hidden = false; await document.dispatchEvent({type: 'visibilitychange'});
  await key('keydown', 'F8', {repeat: true});
  assert.equal(document.body.classList.contains('screenshot-view'), true, 'Held F8 must not toggle repeatedly');
  await key('keydown', 'Escape');
  assert.equal(document.body.classList.contains('screenshot-view'), false);
  assert.equal(nodes.get('pause').hidden, false); assert.equal(input().active, false);
  await click('screenshot-mode'); assert.equal(nodes.get('pause').hidden, true);
  await click('screenshot-exit'); assert.equal(nodes.get('pause').hidden, false); assert.equal(input().active, false);
  await click('screenshot-mode'); await key('keydown', 'F8');
  assert.equal(nodes.get('pause').hidden, false); assert.equal(input().active, false);
  await click('resume'); assert.equal(input().active, true); assert.deepEqual(input().held, {});
  document.hidden = true; await document.dispatchEvent({type: 'visibilitychange'}); assert.equal(input().active, false);
  console.log('Fast input checks passed: held keys, accumulated mouse deltas, edge draining, fire/aim/reload, armory, enlarged-map HUD, pause isolation, screenshot view across focus loss, and feedback fallback.');
})().catch(error => { console.error(error); process.exitCode = 1; });
