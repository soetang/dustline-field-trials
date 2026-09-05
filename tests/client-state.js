'use strict';
// Representative renderer-to-HUD packet for fast, GPU-independent UI checks.
module.exports = () => ({
  phase: 'buy', round: 1, phaseTime: 7, time: 90, buyTime: 20, scores: [0, 0], health: 100, armor: 100, money: 8000,
  weapon: 'M4A4', slot: 0, ammo: 30, reserve: 90, reload: 0, reloadTime: 2.25, kills: 0, deaths: 0, alive: [5, 5],
  bots: Array.from({length: 9}, (_, i) => ({name: `BOT ${i}`, team: i < 4 ? 'CT' : 'T', health: 100, kills: 0, deaths: 0, spotted: 0, x: 32, z: i < 4 ? 8 : 40, intent: i < 4 ? 'HOLDING' : 'ADVANCING'})),
  feed: [], map: Array.from({length: 48}, () => Array(64).fill(0)), spawn: [32.4, 7.6], attackerSpawn: [32.8, 40.2], sites: [[11.6, 8.8], [52.2, 9.6]], layoutScale: 2,
  x: 32.4, z: 7.6, yaw: 3.14, pitch: 0.1, elevation: 0, aiming: false, moving: false, recoil: 0,
  bomb: {state: 'carried', site: 'A', x: 32, z: 40, time: 35, defuse: 0, defuser: null, near: false},
  notice: '', reason: '', winner: 'CT', hitmarker: 0, damage: 0, shots: 0, hurts: 0, eliminations: 0, fps: 60,
});
