(() => {
  'use strict';

  const canvas = document.querySelector('#game');
  const ctx = canvas.getContext('2d', { alpha: false });
  const radar = document.querySelector('#minimap');
  const rctx = radar.getContext('2d');
  const $ = (selector) => document.querySelector(selector);
  const demoMode = new URLSearchParams(window.location?.search || '').has('demo');

  const ui = {
    menu: $('#menu'), pause: $('#pause'), hud: $('#hud'), play: $('#play-button'), resume: $('#resume-button'),
    ctScore: $('#ct-score'), tScore: $('#t-score'), timer: $('#round-timer'), round: $('#round-label'),
    objective: $('#objective'), health: $('#health'), armor: $('#armor'), ammo: $('#ammo'), reserve: $('#reserve'), weaponName: $('#weapon-name'),
    killfeed: $('#killfeed'), roundEnd: $('#round-end'), winner: $('#winner-kicker'), reason: $('#winner-reason'),
    siteBanner: $('#site-banner'), interaction: $('#interaction'), interactionText: $('#interaction-text'),
    interactionFill: $('#interaction-fill'), damage: $('#damage-vignette'), flash: $('#flash'),
    scope: $('#scope'), scoreboard: $('#classic-scoreboard'), scoreRows: $('#classic-score-rows'), alive: $('#alive-count'), result: $('#classic-result'), resultTitle: $('#classic-result-title'), resultStats: $('#classic-result-stats'),
    buyMenu: $('#buy-menu'), buyMoney: $('#buy-money'), hudMoney: $('#money'), buyTimer: $('#buy-timer')
  };

  const MAP_W = 32;
  const MAP_H = 24;
  const BASE_FOV = Math.PI / 2.75;
  let FOV = BASE_FOV;
  let sensitivity = 1, volume = .6, pauseState = 'playing', spectatorIndex = 0, lastHeadshot = false;
  let currentDefuser = null;
  try { const prefs = JSON.parse(localStorage.getItem('desert-strike-classic') || '{}'); sensitivity = Math.min(2.5, Math.max(.3, prefs.sensitivity || 1)); volume = Math.min(1, Math.max(0, prefs.volume ?? .6)); } catch {}
  const projectionScale = () => Math.tan(BASE_FOV / 2) / Math.tan(FOV / 2);
  const grid = Array.from({ length: MAP_H }, () => Array(MAP_W).fill(1));
  const carve = (x1, y1, x2, y2) => {
    for (let y = y1; y <= y2; y++) for (let x = x1; x <= x2; x++) grid[y][x] = 0;
  };

  // A compact three-lane layout: Long A / Catwalk, Mid, and B Tunnels.
  [
    [2, 2, 10, 7], [22, 2, 29, 8], [14, 2, 20, 6], [13, 19, 18, 22],
    [13, 5, 18, 20], [2, 6, 5, 20], [2, 17, 14, 21], [5, 4, 14, 7],
    [8, 9, 14, 12], [7, 6, 10, 10], [23, 7, 28, 20], [18, 18, 28, 21],
    [19, 5, 24, 8], [18, 4, 23, 6], [18, 13, 25, 16], [16, 12, 20, 15]
  ].forEach((rect) => carve(...rect));

  // Solid cover. Different values produce different procedural wall materials.
  [[7, 3, 3], [9, 6, 3], [4, 10, 3], [4, 18, 3], [9, 19, 3], [11, 6, 2],
   [15, 9, 2], [17, 14, 3], [19, 5, 3], [23, 5, 3], [25, 3, 3], [28, 7, 3],
   [25, 11, 3], [23, 15, 3], [26, 19, 3]].forEach(([x, y, tile]) => grid[y][x] = tile);

  const sites = {
    A: { x: 5.8, y: 4.4, radius: 2.1, color: '#de9350' },
    B: { x: 26.1, y: 4.8, radius: 2.0, color: '#de9350' }
  };
  const secret = { x: 2.55, y: 3.25, discovered: false };
  const patrolPoints = [
    { x: 9, y: 7 }, { x: 15, y: 9 }, { x: 20, y: 6 }, { x: 24, y: 8 },
    { x: 4, y: 13 }, { x: 17, y: 14 }, { x: 24, y: 14 }, { x: 15, y: 18 }
  ];
  const WEAPONS = {
    m4: { id: 'm4', name: 'M4A4', price: 3100, mag: 30, reserve: 90, damage: 31, variance: 7, fireRate: .092, reload: 2.25, spread: .007, moveSpread: .022 },
    ak: { id: 'ak', name: 'AK-47', price: 2700, mag: 30, reserve: 90, damage: 36, variance: 8, fireRate: .1, reload: 2.4, spread: .011, moveSpread: .031 },
    awp: { id: 'awp', name: 'AWP', price: 4750, mag: 10, reserve: 30, damage: 112, variance: 9, fireRate: 1.08, reload: 3.15, spread: .0015, moveSpread: .065 },
    deagle: { id: 'deagle', name: 'DESERT EAGLE', price: 700, mag: 7, reserve: 35, damage: 54, variance: 10, fireRate: .29, reload: 2.05, spread: .009, moveSpread: .038 }
  };
  const buySlots = { Digit1: 'm4', Digit2: 'ak', Digit3: 'awp', Digit4: 'deagle' };

  const player = {
    x: 16.2, y: 3.8, angle: Math.PI / 2, pitch: 0, radius: .22, speed: 3.2,
    health: 100, armor: 100, alive: true, ammo: 30, reserve: 90, mag: 30,
    firing: false, fireCooldown: 0, reloading: 0, recoil: 0, sway: 0, defuse: 0,
    team: 'CT', name: 'YOU', weapon: 'm4', aiming: false, kills: 0, deaths: 0
  };

  const ctSpawns = [[15.1, 3.5], [17.2, 3.4], [15.2, 5.1], [18.3, 5.2]];
  const tSpawns = [[14.1, 20.2], [15.3, 21.1], [16.4, 20.1], [17.6, 21.1], [17.5, 19.5]];
  const ctNames = ['FALCON', 'BISHOP', 'NOVA', 'LOCKE'];
  const tNames = ['VIPER', 'ROOK', 'DUNE', 'RAZOR', 'KANE'];
  let bots = [];
  let keys = Object.create(null);
  let started = false;
  let state = 'menu';
  let lastTime = 0;
  let roundTime = 90;
  let roundNumber = 1;
  let ctScore = 0;
  let tScore = 0;
  let roundResetAt = 0;
  let targetSite = 'A';
  let money = 8000;
  let buyTime = 18;
  let bomb = { state: 'carried', carrier: null, x: 0, y: 0, timer: 35, plant: 0, site: null };
  let audio = null;
  let muzzle = 0;
  let hitmarker = 0;
  let shake = 0;
  let visualTime = 0;
  const zBuffer = [];

  function makeBot(team, i, spawn) {
    return {
      team, name: team === 'CT' ? ctNames[i] : tNames[i], kills: 0, deaths: 0, x: spawn[0], y: spawn[1], spawn,
      angle: team === 'CT' ? Math.PI / 2 : -Math.PI / 2, radius: .2, health: 100, alive: true,
      path: [], pathIndex: 0, think: Math.random() * .4, fireCooldown: .4 + Math.random(),
      target: null, patrol: i, carrier: false, plant: 0, flash: 0, stride: Math.random() * 8
    };
  }

  function resetBots() {
    const scores = new Map(bots.map(b => [b.name, [b.kills, b.deaths]]));
    bots = [
      ...ctSpawns.map((p, i) => makeBot('CT', i, p)),
      ...tSpawns.map((p, i) => makeBot('T', i, p))
    ];
    bots.forEach(b => { const stats = scores.get(b.name); if (stats) [b.kills, b.deaths] = stats; });
  }

  function resize() {
    const scale = Math.min(window.devicePixelRatio || 1, 1.25);
    canvas.width = Math.floor(innerWidth * scale);
    canvas.height = Math.floor(innerHeight * scale);
  }

  function isSolid(x, y) {
    const gx = Math.floor(x), gy = Math.floor(y);
    return gx < 0 || gy < 0 || gx >= MAP_W || gy >= MAP_H || grid[gy][gx] !== 0;
  }

  function canStand(x, y, radius = .2) {
    return !isSolid(x - radius, y - radius) && !isSolid(x + radius, y - radius) &&
      !isSolid(x - radius, y + radius) && !isSolid(x + radius, y + radius);
  }

  function moveEntity(entity, dx, dy) {
    if (canStand(entity.x + dx, entity.y, entity.radius)) entity.x += dx;
    if (canStand(entity.x, entity.y + dy, entity.radius)) entity.y += dy;
  }

  function normalizeAngle(a) {
    while (a > Math.PI) a -= Math.PI * 2;
    while (a < -Math.PI) a += Math.PI * 2;
    return a;
  }

  function distance(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }

  function castRay(ox, oy, angle, maxDistance = 40) {
    const rayX = Math.cos(angle), rayY = Math.sin(angle);
    let mapX = Math.floor(ox), mapY = Math.floor(oy);
    const deltaX = Math.abs(1 / (rayX || .00001));
    const deltaY = Math.abs(1 / (rayY || .00001));
    const stepX = rayX < 0 ? -1 : 1, stepY = rayY < 0 ? -1 : 1;
    let sideX = rayX < 0 ? (ox - mapX) * deltaX : (mapX + 1 - ox) * deltaX;
    let sideY = rayY < 0 ? (oy - mapY) * deltaY : (mapY + 1 - oy) * deltaY;
    let side = 0, dist = 0, tile = 1;
    for (let i = 0; i < 80; i++) {
      if (sideX < sideY) { sideX += deltaX; mapX += stepX; side = 0; dist = sideX - deltaX; }
      else { sideY += deltaY; mapY += stepY; side = 1; dist = sideY - deltaY; }
      if (dist > maxDistance || mapX < 0 || mapY < 0 || mapX >= MAP_W || mapY >= MAP_H) break;
      tile = grid[mapY][mapX];
      if (tile) {
        const hit = side === 0 ? oy + dist * rayY : ox + dist * rayX;
        return { distance: dist, side, tile, offset: hit - Math.floor(hit), mapX, mapY };
      }
    }
    return { distance: maxDistance, side, tile: 1, offset: 0, mapX, mapY };
  }

  function clearLine(a, b) {
    const d = distance(a, b);
    if (d < .01) return true;
    return castRay(a.x, a.y, Math.atan2(b.y - a.y, b.x - a.x), d + .05).distance >= d - .18;
  }

  function nearestFloor(x, y) {
    x = Math.max(1, Math.min(MAP_W - 2, Math.floor(x)));
    y = Math.max(1, Math.min(MAP_H - 2, Math.floor(y)));
    if (!grid[y][x]) return [x, y];
    for (let r = 1; r < 6; r++) {
      for (let yy = y - r; yy <= y + r; yy++) for (let xx = x - r; xx <= x + r; xx++) {
        if (grid[yy]?.[xx] === 0) return [xx, yy];
      }
    }
    return [x, y];
  }

  function findPath(sx, sy, tx, ty) {
    const [startX, startY] = nearestFloor(sx, sy);
    const [goalX, goalY] = nearestFloor(tx, ty);
    const queue = [[startX, startY]];
    const visited = Array.from({ length: MAP_H }, () => Array(MAP_W).fill(false));
    const parent = Array.from({ length: MAP_H }, () => Array(MAP_W).fill(null));
    visited[startY][startX] = true;
    const dirs = [[1, 0], [-1, 0], [0, 1], [0, -1]];
    for (let head = 0; head < queue.length; head++) {
      const [x, y] = queue[head];
      if (x === goalX && y === goalY) break;
      for (const [dx, dy] of dirs) {
        const nx = x + dx, ny = y + dy;
        if (nx > 0 && ny > 0 && nx < MAP_W - 1 && ny < MAP_H - 1 && !visited[ny][nx] && grid[ny][nx] === 0) {
          visited[ny][nx] = true; parent[ny][nx] = [x, y]; queue.push([nx, ny]);
        }
      }
    }
    if (!visited[goalY][goalX]) return [];
    const result = [];
    let node = [goalX, goalY];
    while (node && (node[0] !== startX || node[1] !== startY)) {
      result.push({ x: node[0] + .5, y: node[1] + .5 });
      node = parent[node[1]][node[0]];
    }
    return result.reverse();
  }

  function strategicTarget(bot) {
    if (bot.team === 'T') {
      if (bomb.state === 'dropped') return { x: bomb.x, y: bomb.y };
      if (bomb.state === 'planted') return { x: bomb.x + (bot.patrol % 2 ? 1.2 : -1.2), y: bomb.y + (bot.patrol % 3 - 1) };
      if (bot.carrier) return sites[targetSite];
      const carrier = bomb.carrier?.alive ? bomb.carrier : null;
      return carrier ? { x: carrier.x + (bot.patrol % 2 ? 1 : -1), y: carrier.y + (bot.patrol % 3 - 1) } : sites[targetSite];
    }
    if (bomb.state === 'planted') return bomb;
    const defense = targetSite === 'A'
      ? [{ x: 8.5, y: 6.5 }, { x: 11.5, y: 10.5 }, { x: 15.5, y: 8.5 }, { x: 19.5, y: 6.5 }]
      : [{ x: 21.5, y: 6.5 }, { x: 24.5, y: 8.5 }, { x: 18.5, y: 14.5 }, { x: 15.5, y: 9.5 }];
    return defense[bot.patrol % defense.length];
  }

  function livingEnemies(bot) {
    const list = bots.filter((other) => other.alive && other.team !== bot.team);
    if (player.alive && player.team !== bot.team) list.push(player);
    return list;
  }

  function updateBot(bot, dt) {
    if (!bot.alive || state !== 'playing') return;
    bot.think -= dt; bot.fireCooldown -= dt; bot.flash = Math.max(0, bot.flash - dt * 6);
    let visible = livingEnemies(bot)
      .filter((enemy) => distance(bot, enemy) < 9.5 && clearLine(bot, enemy))
      .sort((a, b) => distance(bot, a) - distance(bot, b))[0];

    if (visible) {
      bot.target = visible;
      const desired = Math.atan2(visible.y - bot.y, visible.x - bot.x);
      bot.angle += normalizeAngle(desired - bot.angle) * Math.min(1, dt * 7);
      const d = distance(bot, visible);
      if (d > 4.2) moveEntity(bot, Math.cos(bot.angle) * dt * 1.15, Math.sin(bot.angle) * dt * 1.15);
      if (bot.fireCooldown <= 0 && Math.abs(normalizeAngle(desired - bot.angle)) < .12) {
        bot.fireCooldown = .45 + Math.random() * .5 + d * .025;
        bot.flash = 1; playBotShot(bot);
        const accuracy = Math.max(.28, .88 - d * .055);
        if (Math.random() < accuracy) damageEntity(visible, 8 + Math.floor(Math.random() * 13), bot);
      }
    } else {
      bot.target = null;
      if (bot.think <= 0 || bot.pathIndex >= bot.path.length) {
        bot.think = .65 + Math.random() * .5;
        const target = strategicTarget(bot);
        bot.path = findPath(bot.x, bot.y, target.x, target.y);
        bot.pathIndex = 0;
      }
      const waypoint = bot.path[bot.pathIndex];
      if (waypoint) {
        const d = distance(bot, waypoint);
        if (d < .22) bot.pathIndex++;
        else {
          const desired = Math.atan2(waypoint.y - bot.y, waypoint.x - bot.x);
          bot.angle += normalizeAngle(desired - bot.angle) * Math.min(1, dt * 8);
          const speed = bot.team === 'T' ? 1.55 : 1.35;
          moveEntity(bot, Math.cos(bot.angle) * speed * dt, Math.sin(bot.angle) * speed * dt);
          bot.stride += dt * 9;
        }
      }
    }

    if (bot.team === 'T') updateTObjective(bot, dt, visible);
  }

  function updateTObjective(bot, dt, enemyVisible) {
    if (bomb.state === 'dropped' && distance(bot, bomb) < .55) {
      bomb.state = 'carried'; bomb.carrier = bot; bot.carrier = true; addNotice(`${bot.name} picked up the bomb`);
    }
    if (bot.carrier && bomb.state === 'carried') {
      bomb.x = bot.x; bomb.y = bot.y;
      const site = sites[targetSite];
      if (distance(bot, site) < site.radius && !enemyVisible) {
        bot.plant += dt; bomb.plant = bot.plant;
        if (bot.plant >= 3.2) plantBomb(bot);
      } else bot.plant = Math.max(0, bot.plant - dt * 2);
    }
  }

  function plantBomb(bot) {
    bomb = { state: 'planted', carrier: null, x: bot.x, y: bot.y, timer: 35, plant: 0, site: targetSite };
    bot.carrier = false;
    ui.siteBanner.hidden = false;
    ui.siteBanner.textContent = `BOMB PLANTED · SITE ${targetSite}`;
    ui.objective.textContent = 'DEFUSE THE BOMB';
    sound('plant');
    addNotice(`Bomb planted at Site ${targetSite}`);
  }

  function damageEntity(target, amount, attacker) {
    if (!target.alive || state !== 'playing') return;
    if (target === player) {
      const absorbed = Math.min(target.armor, Math.ceil(amount * .45));
      target.armor -= absorbed;
      target.health -= amount - Math.floor(absorbed * .35);
      ui.damage.style.opacity = '.75';
      setTimeout(() => { ui.damage.style.opacity = '0'; }, 80);
      shake = Math.min(8, shake + 2.5);
    } else target.health -= amount;
    if (target.health <= 0) killEntity(target, attacker);
  }

  function killEntity(victim, attacker) {
    victim.health = 0; victim.alive = false; victim.deaths++; attacker.kills++;
    if (victim === currentDefuser) { currentDefuser = null; player.defuse = 0; }
    if (victim.carrier) {
      victim.carrier = false;
      bomb = { state: 'dropped', carrier: null, x: victim.x, y: victim.y, timer: 35, plant: 0, site: null };
      addNotice('The bomb has been dropped');
    }
    addKill(attacker, victim);
    if (attacker === player) money = Math.min(16000, money + 300);
    sound(victim === player ? 'death' : 'hit');
    if (victim === player) {
      ui.objective.textContent = 'YOU ARE DOWN';
      player.firing = false; player.aiming = false;
    }
  }

  function addKill(attacker, victim) {
    const row = document.createElement('div');
    row.className = `kill ${attacker.team.toLowerCase()}`;
    row.innerHTML = `<b class="${attacker.team.toLowerCase()}">${attacker.name}</b><i>◆</i><b class="${victim.team.toLowerCase()}">${victim.name}</b>`;
    ui.killfeed.prepend(row);
    setTimeout(() => row.remove(), 5000);
  }

  function addNotice(message) {
    const row = document.createElement('div');
    row.className = 'kill'; row.textContent = message;
    ui.killfeed.prepend(row); setTimeout(() => row.remove(), 3500);
  }

  function playerShoot() {
    if (!player.alive || player.fireCooldown > 0 || player.reloading > 0 || state !== 'playing') return;
    if (player.ammo <= 0) { player.fireCooldown = .2; sound('empty'); return; }
    const weapon = WEAPONS[player.weapon];
    player.ammo--; player.fireCooldown = weapon.fireRate; player.recoil = Math.min(1, player.recoil + (weapon.id === 'awp' ? .58 : .19)); muzzle = .065; shake = Math.min(5, shake + (weapon.id === 'awp' ? 2.2 : .7));
    sound('shot');
    const moving = keys.KeyW || keys.KeyA || keys.KeyS || keys.KeyD;
    const spread = (moving ? weapon.moveSpread : weapon.spread) + player.recoil * (weapon.id === 'awp' ? .006 : .018);
    const shotAngle = player.angle + (Math.random() - .5) * spread * (player.aiming && !moving ? .22 : 1);
    const wallDistance = castRay(player.x, player.y, shotAngle).distance;
    const dx = Math.cos(shotAngle), dy = Math.sin(shotAngle);
    let hit = null, hitProjection = Infinity;
    for (const bot of bots) {
      if (!bot.alive) continue;
      const rx = bot.x - player.x, ry = bot.y - player.y;
      const projection = rx * dx + ry * dy;
      const perpendicular = Math.abs(rx * dy - ry * dx);
      const height = Math.min(canvas.height * 1.7, canvas.height / Math.max(.3, projection) * .82 * projectionScale());
      const aimHeight = .5 - (player.pitch + Math.sin(player.sway) * 2) / height;
      if (projection > 0 && projection < wallDistance && perpendicular < .25 && projection < hitProjection && aimHeight > .23 && aimHeight < .98) {
        hit = bot; hitProjection = projection;
      }
    }
    if (hit) {
      if (hit.team === player.team) { addNotice('FRIENDLY — HOLD FIRE'); return; }
      const height = Math.min(canvas.height * 1.7, canvas.height / Math.max(.3, hitProjection) * .82 * projectionScale());
      const headshot = .5 - (player.pitch + Math.sin(player.sway) * 2) / height < .43;
      lastHeadshot = headshot;
      const damage = headshot ? Math.max(100, weapon.damage * 3.5) : weapon.damage + Math.floor(Math.random() * weapon.variance);
      damageEntity(hit, damage, player); hitmarker = .15; sound('hit');
    }
  }

  function startReload() {
    if (state !== 'playing' || !player.alive || player.reloading || player.ammo === player.mag || player.reserve <= 0) return;
    player.reloading = WEAPONS[player.weapon].reload; sound('reload');
  }

  function trySecret() {
    if (secret.discovered || !player.alive || distance(player, secret) > 1.25) return;
    secret.discovered = true;
    money += 1600;
    ui.weaponName.textContent = `${WEAPONS[player.weapon].name} // RELIC`;
    addNotice('RELIC RECOVERED · SOME SECRETS STAY BURIED');
    if (audio) {
      tone(330, .14, 'triangle', .035, 110);
      setTimeout(() => tone(495, .14, 'triangle', .035, 165), 140);
      setTimeout(() => tone(660, .28, 'triangle', .04, 220), 280);
    }
  }

  function finishReload() {
    const needed = player.mag - player.ammo;
    const loaded = Math.min(needed, player.reserve);
    player.ammo += loaded; player.reserve -= loaded;
  }

  function updatePlayer(dt) {
    const targetFov = player.aiming && player.alive ? (player.weapon === 'awp' ? .34 : BASE_FOV * .72) : BASE_FOV;
    FOV += (targetFov - FOV) * Math.min(1, dt * 15);
    if (!player.alive) {
      const surviving = bots.filter(b => b.alive && b.team === 'CT');
      const watching = surviving[spectatorIndex % Math.max(1, surviving.length)];
      if (watching) { player.x = watching.x; player.y = watching.y; player.angle = watching.angle; player.pitch = 0; ui.objective.textContent = 'SPECTATING ' + watching.name + ' · C TO SWITCH'; }
    }
    player.fireCooldown = Math.max(0, player.fireCooldown - dt);
    player.recoil = Math.max(0, player.recoil - dt * .62);
    muzzle = Math.max(0, muzzle - dt); hitmarker = Math.max(0, hitmarker - dt); shake *= Math.pow(.02, dt);
    if (player.reloading > 0) {
      const before = player.reloading; player.reloading = Math.max(0, player.reloading - dt);
      if (before > 0 && player.reloading === 0) finishReload();
    }
    if (!player.alive || state !== 'playing') return;
    let forward = (keys.KeyW ? 1 : 0) - (keys.KeyS ? 1 : 0);
    let strafe = (keys.KeyD ? 1 : 0) - (keys.KeyA ? 1 : 0);
    const length = Math.hypot(forward, strafe) || 1;
    forward /= length; strafe /= length;
    const walk = keys.ShiftLeft || keys.ShiftRight;
    const speed = player.speed * (keys.ControlLeft ? .38 : walk || player.aiming ? .48 : 1);
    const dx = (Math.cos(player.angle) * forward + Math.cos(player.angle + Math.PI / 2) * strafe) * speed * dt;
    const dy = (Math.sin(player.angle) * forward + Math.sin(player.angle + Math.PI / 2) * strafe) * speed * dt;
    moveEntity(player, dx, dy);
    player.sway += Math.hypot(dx, dy) * (walk ? 8 : 12);
    if (player.firing && (player.weapon === 'm4' || player.weapon === 'ak')) playerShoot();
    if (player.ammo === 0 && player.reserve > 0 && !player.reloading) startReload();
  }

  function updateBuyMenu() {
    ui.buyMoney.textContent = `$${money.toLocaleString()}`;
    ui.buyTimer.textContent = Math.max(0, Math.ceil(buyTime));
    for (const card of ui.buyMenu.querySelectorAll?.('[data-slot]') || []) {
      const weapon = WEAPONS[buySlots[`Digit${card.dataset.slot}`]];
      card.classList.toggle('affordable', money >= weapon.price);
    }
  }

  function toggleBuyMenu() {
    if (state === 'buying') {
      state = 'playing'; ui.buyMenu.hidden = true;
      captureMouse(); return;
    }
    if (state !== 'playing' || !player.alive || buyTime <= 0) return;
    state = 'buying'; player.firing = false; player.aiming = false; ui.buyMenu.hidden = false; updateBuyMenu();
    document.exitPointerLock?.();
  }

  function buyWeapon(id) {
    if (state !== 'buying' || buyTime <= 0 || !player.alive) return;
    const weapon = WEAPONS[id];
    if (!weapon || money < weapon.price) { sound('empty'); return; }
    money -= weapon.price; player.weapon = id; player.mag = weapon.mag; player.ammo = weapon.mag; player.reserve = weapon.reserve; player.reloading = 0;
    ui.weaponName.textContent = `${weapon.name}${secret.discovered ? ' // RELIC' : ''}`;
    sound('reload'); updateBuyMenu();
  }

  function updateObjective(dt) {
    ui.interaction.classList.remove('active');
    if (bomb.state === 'planted') {
      bomb.timer -= dt;
      if (Math.ceil(bomb.timer) % 2 === 0 && Math.ceil(bomb.timer + dt) % 2 !== 0) sound('beep');
      let defuser = null;
      if (bomb.timer <= 0) { explodeBomb(); endRound('T', `SITE ${bomb.site} DESTROYED`); return; }
      if (player.alive && distance(player, bomb) < 1.25 && keys.KeyE && clearLine(player, bomb)) defuser = player;
      if (!defuser) defuser = bots.find((b) => b.alive && b.team === 'CT' && !b.target && distance(b, bomb) < .7 && clearLine(b, bomb));
      if (defuser !== currentDefuser) player.defuse = 0;
      currentDefuser = defuser;
      if (defuser) {
        player.defuse += dt;
        if (defuser === player) {
          ui.interaction.classList.add('active'); ui.interactionText.textContent = 'DEFUSING';
          ui.interactionFill.style.width = `${Math.min(100, player.defuse / 5 * 100)}%`;
        }
        if (player.defuse >= 5) endRound('CT', 'BOMB DEFUSED');
      } else player.defuse = 0;
      if (bomb.timer <= 0) { explodeBomb(); endRound('T', `SITE ${bomb.site} DESTROYED`); }
    } else {
      player.defuse = 0;
      const carrier = bomb.carrier;
      if (carrier?.plant > 0) {
        ui.interaction.classList.add('active');
        ui.interactionText.textContent = `ENEMY PLANTING AT ${targetSite}`;
        ui.interactionFill.style.width = `${carrier.plant / 3.2 * 100}%`;
      }
    }
  }

  function explodeBomb() {
    sound('explosion'); ui.flash.style.opacity = '1';
    setTimeout(() => { ui.flash.style.transition = 'opacity 1.2s'; ui.flash.style.opacity = '0'; }, 80);
    shake = 18;
  }

  function updateRound(dt, now) {
    if (state === 'roundover') {
      roundResetAt -= dt;
      if (roundResetAt <= 0) startRound();
      return;
    }
    if (state !== 'playing') return;
    buyTime = Math.max(0, buyTime - dt);
    if (bomb.state !== 'planted') roundTime -= dt;
    updateObjective(dt);
    const terroristsAlive = bots.some((b) => b.team === 'T' && b.alive);
    const ctsAlive = player.alive || bots.some((b) => b.team === 'CT' && b.alive);
    if (!terroristsAlive && bomb.state !== 'planted') endRound('CT', 'ENEMY TEAM ELIMINATED');
    else if (!ctsAlive) endRound('T', 'COUNTER-TERRORISTS ELIMINATED');
    else if (roundTime <= 0 && bomb.state !== 'planted') endRound('CT', 'TIME EXPIRED');
  }

  function endRound(team, reason) {
    if (state !== 'playing') return;
    state = 'roundover';
    if (team === 'CT') ctScore++; else tScore++;
    money = Math.min(16000, money + (team === 'CT' ? 3250 : 1900));
    ui.ctScore.textContent = ctScore; ui.tScore.textContent = tScore;
    ui.winner.textContent = `${team === 'CT' ? 'COUNTER-TERRORISTS' : 'TERRORISTS'} WIN`;
    ui.winner.style.color = team === 'CT' ? '#79a9d7' : '#d7ab72';
    ui.reason.textContent = reason; ui.roundEnd.hidden = false; ui.siteBanner.hidden = true;
    roundResetAt = 4.2;
    if (ctScore >= 5 || tScore >= 5) {
      state = 'matchover'; player.firing = false; player.aiming = false; ui.roundEnd.hidden = true; ui.result.hidden = false;
      ui.resultTitle.textContent = team === 'CT' ? 'MISSION SECURED' : 'MISSION LOST';
      ui.resultStats.textContent = `${ctScore} : ${tScore} · ${player.kills} ELIMINATIONS · ${player.deaths} DEATHS`;
      document.exitPointerLock?.();
    }
    sound(team === 'CT' ? 'win' : 'loss');
  }

  function startRound() {
    resetBots();
    player.x = 16.2; player.y = 3.8; player.angle = Math.PI / 2; player.pitch = 0;
    player.health = 100; player.armor = 100; player.alive = true;
    const weapon = WEAPONS[player.weapon]; player.mag = weapon.mag; player.ammo = weapon.mag; player.reserve = weapon.reserve;
    player.reloading = 0; player.defuse = 0; player.firing = false; player.aiming = false; player.fireCooldown = 0; player.recoil = 0; FOV = BASE_FOV; currentDefuser = null; keys = Object.create(null);
    roundTime = 90; buyTime = 18; roundNumber++; targetSite = Math.random() < .5 ? 'A' : 'B';
    const carrier = bots.find((b) => b.team === 'T');
    carrier.carrier = true;
    bomb = { state: 'carried', carrier, x: carrier.x, y: carrier.y, timer: 35, plant: 0, site: null };
    state = 'playing'; ui.roundEnd.hidden = true; ui.siteBanner.hidden = true; ui.buyMenu.hidden = true;
    ui.round.textContent = `ROUND ${roundNumber}`; ui.objective.textContent = 'DEFEND THE SITES'; ui.weaponName.textContent = `${weapon.name}${secret.discovered ? ' // RELIC' : ''}`;
    ui.interaction.classList.remove('active'); ui.killfeed.innerHTML = '';
    if (!demoMode && document.pointerLockElement !== canvas && started) { pauseState = 'playing'; state = 'paused'; ui.pause.hidden = false; }
  }

  function wallColor(hit, distance, x) {
    const shade = (hit.side ? .72 : .96) * (1 - Math.min(.32, distance / 65));
    let base;
    if (hit.tile === 3) base = [111, 75, 39];
    else if (hit.tile === 2) base = [139, 116, 88];
    else base = [205, 169, 119];
    const grit = ((((hit.mapX * 17 + hit.mapY * 31 + Math.floor(hit.offset * 19)) * 13) % 11) - 5) * 1.3;
    const joint = hit.tile === 1 && (Math.floor(hit.offset * 10) === ((hit.mapX + hit.mapY) & 1 ? 0 : 5));
    if (joint) base = [156, 128, 92];
    const fog = Math.max(0, Math.min(.72, (distance - 7) / 24));
    const fogColor = [186, 171, 148];
    return `rgb(${base.map((value, index) => Math.floor((value * shade + grit) * (1 - fog) + fogColor[index] * fog)).join(',')})`;
  }

  function drawAtmosphere(w, h, horizon) {
    const sunAngle = normalizeAngle(-2.15 - player.angle);
    if (Math.abs(sunAngle) < FOV * .8) {
      const sunX = w / 2 + Math.tan(sunAngle) / Math.tan(FOV / 2) * w / 2;
      const sunY = horizon - h * .28;
      const glow = ctx.createRadialGradient(sunX, sunY, 2, sunX, sunY, h * .16);
      glow.addColorStop(0, '#fff8d8'); glow.addColorStop(.09, '#ffe8a8dd'); glow.addColorStop(1, '#f2ba5720');
      ctx.fillStyle = glow; ctx.beginPath(); ctx.arc(sunX, sunY, h * .16, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#fff4c8'; ctx.beginPath(); ctx.arc(sunX, sunY, h * .026, 0, Math.PI * 2); ctx.fill();
    }

    ctx.fillStyle = '#eef2e916';
    for (let i = 0; i < 5; i++) {
      const cloudX = ((i * w * .29 + visualTime * (2 + i * .3)) % (w * 1.35)) - w * .18;
      const cloudY = horizon * (.2 + (i % 3) * .13);
      ctx.beginPath(); ctx.ellipse(cloudX, cloudY, w * .09, h * .018, 0, 0, Math.PI * 2); ctx.fill();
    }

    // A hazy, low desert skyline provides depth beyond the playable walls.
    ctx.fillStyle = '#766f6160';
    const skyline = [[0,.12,.12],[.09,.08,.09],[.18,.18,.15],[.34,.1,.08],[.48,.16,.13],[.61,.08,.07],[.69,.2,.16],[.86,.11,.1],[.94,.16,.13]];
    for (const [x, width, height] of skyline) ctx.fillRect(x * w, horizon - height * h, width * w, height * h + 2);

    ctx.strokeStyle = '#f0d6a112'; ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = -8; i <= 8; i++) {
      ctx.moveTo(w / 2 + i * 5, horizon); ctx.lineTo(w / 2 + i * w * .115, h);
    }
    ctx.stroke();
    ctx.fillStyle = '#fff2cd14';
    for (let y = horizon + 18; y < h; y += Math.max(6, (y - horizon) * .21)) ctx.fillRect(0, y, w, 1);
  }

  function drawDustAndGrade(w, h, horizon) {
    for (let i = 0; i < 34; i++) {
      const speed = 4 + (i % 7) * 1.7;
      const x = ((i * 193 + visualTime * speed + player.angle * 28) % (w + 80)) - 40;
      const y = horizon * .55 + ((i * 83 + Math.sin(visualTime * .35 + i) * 45) % Math.max(1, h - horizon * .45));
      const radius = .45 + (i % 4) * .38;
      ctx.fillStyle = `rgba(255,226,174,${.025 + (i % 3) * .012})`;
      ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2); ctx.fill();
    }
    const vignette = ctx.createRadialGradient(w / 2, h * .44, h * .2, w / 2, h * .48, w * .68);
    vignette.addColorStop(0, '#00000000'); vignette.addColorStop(.72, '#15100908'); vignette.addColorStop(1, '#090b0d78');
    ctx.fillStyle = vignette; ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = '#e49b3910'; ctx.fillRect(0, 0, w, h);
  }

  function renderWorld() {
    const w = canvas.width, h = canvas.height;
    const bob = player.alive ? Math.sin(player.sway) * 2 : 18;
    const horizon = h / 2 + player.pitch + bob + (Math.random() - .5) * shake;
    const sky = ctx.createLinearGradient(0, 0, 0, horizon);
    sky.addColorStop(0, '#4f789a'); sky.addColorStop(.58, '#a9c1cc'); sky.addColorStop(1, '#e6c48f');
    ctx.fillStyle = sky; ctx.fillRect(0, 0, w, Math.max(0, horizon));
    const floor = ctx.createLinearGradient(0, horizon, 0, h);
    floor.addColorStop(0, '#ad926e'); floor.addColorStop(.42, '#736249'); floor.addColorStop(1, '#292722');
    ctx.fillStyle = floor; ctx.fillRect(0, horizon, w, h - horizon);
    drawAtmosphere(w, h, horizon);

    const step = w > 1300 ? 2 : 1;
    for (let x = 0; x < w; x += step) {
      const camera = (x / w - .5) * 2;
      const rayAngle = player.angle + Math.atan(camera * Math.tan(FOV / 2));
      const hit = castRay(player.x, player.y, rayAngle);
      const corrected = Math.max(.05, hit.distance * Math.cos(rayAngle - player.angle));
      const wallHeight = Math.min(h * 2.2, h / corrected * projectionScale());
      const top = horizon - wallHeight * .52;
      ctx.fillStyle = wallColor(hit, corrected, x);
      ctx.fillRect(x, top, step + .4, wallHeight);
      if (hit.tile === 1) {
        ctx.fillStyle = hit.side ? '#33271728' : '#fff0c32a';
        for (let course = 1; course < 5; course++) ctx.fillRect(x, top + wallHeight * course / 5, step + .4, Math.max(1, wallHeight * .007));
      } else if (hit.tile === 3) {
        const plank = Math.floor(hit.offset * 6);
        if (plank === 0 || plank === 5) { ctx.fillStyle = '#2113087d'; ctx.fillRect(x, top, step + .4, wallHeight); }
        ctx.fillStyle = '#f2c77b28'; ctx.fillRect(x, top + wallHeight * .08, step + .4, wallHeight * .035);
        ctx.fillStyle = '#1c120944'; ctx.fillRect(x, top + wallHeight * .49, step + .4, wallHeight * .045);
      }
      ctx.fillStyle = hit.side ? '#00000030' : '#fff1cb35'; ctx.fillRect(x, top, step + .4, Math.max(1, wallHeight * .012));
      ctx.fillStyle = '#100c0835'; ctx.fillRect(x, top + wallHeight * .9, step + .4, wallHeight * .1);
      for (let sx = x; sx < Math.min(w, x + step); sx++) zBuffer[sx] = corrected;
    }
    renderWorldSprites(horizon);
    drawDustAndGrade(w, h, horizon);
    renderWeapon(w, h, bob);
  }

  function createBotSprite(team) {
    const c = document.createElement('canvas'); c.width = 96; c.height = 192;
    const g = c.getContext('2d');
    const ct = team === 'CT';
    g.fillStyle = '#171410aa'; g.beginPath(); g.ellipse(48, 184, 28, 7, 0, 0, Math.PI * 2); g.fill();
    g.fillStyle = ct ? '#202f39' : '#4c3522';
    g.fillRect(29, 87, 38, 55);
    g.fillStyle = ct ? '#324b59' : '#6c4c2d';
    g.fillRect(22, 92, 15, 56); g.fillRect(59, 92, 15, 56);
    g.fillStyle = '#171c1e'; g.fillRect(30, 137, 15, 45); g.fillRect(52, 137, 15, 45);
    g.fillStyle = '#17191a'; g.fillRect(25, 176, 22, 9); g.fillRect(51, 176, 22, 9);
    g.fillStyle = '#b48a63'; g.beginPath(); g.arc(48, 64, 19, 0, Math.PI * 2); g.fill();
    g.fillStyle = ct ? '#17252d' : '#c1a07c'; g.fillRect(27, 51, 42, 14);
    g.fillStyle = '#17191a'; g.fillRect(29, 62, 38, 8);
    g.fillStyle = ct ? '#55778c' : '#936f41'; g.fillRect(33, 90, 30, 13);
    g.fillStyle = ct ? '#17232a' : '#33271b'; g.fillRect(36, 106, 10, 18); g.fillRect(51, 106, 10, 18);
    g.fillStyle = '#8a765c'; g.fillRect(31, 128, 35, 7);
    g.fillStyle = ct ? '#79a9be' : '#c89a59'; g.fillRect(24, 97, 5, 34); g.fillRect(68, 97, 5, 34);
    g.fillStyle = '#14191b'; g.fillRect(31, 60, 34, 4);
    g.fillStyle = '#6e8993'; g.fillRect(35, 61, 10, 3); g.fillRect(53, 61, 10, 3);
    g.strokeStyle = '#121518'; g.lineWidth = 9; g.lineCap = 'round';
    g.beginPath(); g.moveTo(32, 102); g.lineTo(58, 118); g.lineTo(80, 116); g.stroke();
    g.strokeStyle = '#272c2e'; g.lineWidth = 6; g.beginPath(); g.moveTo(44, 111); g.lineTo(82, 110); g.stroke();
    g.strokeStyle = '#697477'; g.lineWidth = 1; g.beginPath(); g.moveTo(48, 108); g.lineTo(82, 107); g.stroke();
    g.fillStyle = '#101314'; g.fillRect(59, 111, 8, 17); g.fillStyle = '#4f5658'; g.fillRect(76, 104, 10, 5);
    return c;
  }

  const botSprites = { CT: createBotSprite('CT'), T: createBotSprite('T') };

  function renderWorldSprites(horizon) {
    const sprites = bots.filter((b) => b.alive).map((b) => ({ ...b, type: 'bot', ref: b }));
    if (bomb.state !== 'carried') sprites.push({ x: bomb.x, y: bomb.y, type: 'bomb', ref: bomb });
    for (const [label, site] of Object.entries(sites)) sprites.push({ ...site, type: 'site', label, ref: site });
    sprites.push({ ...secret, type: 'secret', ref: secret });
    sprites.sort((a, b) => distance(player, b) - distance(player, a));
    for (const sprite of sprites) {
      const dx = sprite.x - player.x, dy = sprite.y - player.y;
      const rawDistance = Math.hypot(dx, dy);
      const angle = normalizeAngle(Math.atan2(dy, dx) - player.angle);
      if (Math.abs(angle) > FOV * .7 || rawDistance < .2) continue;
      const depth = rawDistance * Math.cos(angle);
      const screenX = canvas.width / 2 + Math.tan(angle) / Math.tan(FOV / 2) * canvas.width / 2;
      if (sprite.type === 'bot') drawBotSprite(sprite.ref, screenX, depth, horizon);
      else if (sprite.type === 'bomb') drawBombSprite(screenX, depth, horizon);
      else if (sprite.type === 'secret') drawSecretMarker(screenX, depth, horizon);
      else drawSiteMarker(sprite, screenX, depth, horizon);
    }
  }

  function drawClippedImage(image, screenX, top, width, height, depth) {
    const left = Math.floor(screenX - width / 2), right = Math.ceil(screenX + width / 2);
    const slice = Math.max(1, Math.ceil(width / image.width));
    for (let x = left; x < right; x += slice) {
      if (x < 0 || x >= canvas.width || zBuffer[x] < depth - .12) continue;
      const sourceX = Math.max(0, Math.floor((x - left) / width * image.width));
      const sourceW = Math.max(1, Math.ceil(slice / width * image.width));
      ctx.drawImage(image, sourceX, 0, sourceW, image.height, x, top, slice + 1, height);
    }
  }

  function drawBotSprite(bot, screenX, depth, horizon) {
    const height = Math.min(canvas.height * 1.7, canvas.height / Math.max(.3, depth) * .82 * projectionScale());
    const width = height * .5;
    const top = horizon - height * .5 + Math.sin(bot.stride) * height * .012;
    drawClippedImage(botSprites[bot.team], screenX, top, width, height, depth);
    if (bot.flash && depth < 7 && zBuffer[Math.floor(screenX)] > depth - .1) {
      ctx.fillStyle = '#ffd37d'; ctx.beginPath(); ctx.arc(screenX + width * .39, top + height * .56, height * .045 * bot.flash, 0, Math.PI * 2); ctx.fill();
    }
  }

  function drawBombSprite(screenX, depth, horizon) {
    if (zBuffer[Math.max(0, Math.min(canvas.width - 1, Math.floor(screenX)))] < depth - .1) return;
    const size = Math.min(130, canvas.height / Math.max(.4, depth) * .24);
    const y = horizon + canvas.height / Math.max(.4, depth) * .47;
    ctx.fillStyle = '#27231f'; ctx.fillRect(screenX - size * .42, y - size * .7, size * .84, size * .65);
    ctx.fillStyle = bomb.state === 'planted' && Math.floor(bomb.timer * 2) % 2 ? '#ff3228' : '#6b1714';
    ctx.fillRect(screenX - size * .12, y - size * .57, size * .24, size * .18);
    ctx.strokeStyle = '#d6b64e'; ctx.lineWidth = Math.max(1, size * .05); ctx.beginPath(); ctx.arc(screenX, y - size * .7, size * .3, Math.PI, Math.PI * 1.8); ctx.stroke();
  }

  function drawSecretMarker(screenX, depth, horizon) {
    if (depth > 7 || zBuffer[Math.max(0, Math.min(canvas.width - 1, Math.floor(screenX)))] < depth - .08) return;
    const size = Math.min(72, canvas.height / Math.max(.4, depth) * .21);
    const y = horizon + canvas.height / Math.max(.4, depth) * .28;
    ctx.save(); ctx.translate(screenX, y); ctx.rotate(-.035);
    ctx.shadowColor = secret.discovered ? '#f2c15b' : '#9f382c'; ctx.shadowBlur = secret.discovered ? 18 : 4;
    ctx.fillStyle = secret.discovered ? '#7f6328' : '#281d18'; ctx.fillRect(-size * .65, -size * .42, size * 1.3, size * .84);
    ctx.strokeStyle = secret.discovered ? '#f5cf72' : '#a14735'; ctx.lineWidth = Math.max(1, size * .035); ctx.strokeRect(-size * .65, -size * .42, size * 1.3, size * .84);
    ctx.fillStyle = secret.discovered ? '#fff0b4' : '#c99a7b'; ctx.font = `700 ${Math.max(8, size * .2)}px monospace`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(secret.discovered ? 'RELIC // 1.6' : 'F // 1.6', 0, 0); ctx.restore();
  }

  function drawSiteMarker(site, screenX, depth, horizon) {
    if (depth > 11 || zBuffer[Math.max(0, Math.min(canvas.width - 1, Math.floor(screenX)))] < depth) return;
    const size = Math.min(65, canvas.height / depth * .3);
    ctx.globalAlpha = Math.max(.25, 1 - depth / 14);
    ctx.fillStyle = '#b94e32aa'; ctx.beginPath(); ctx.arc(screenX, horizon + canvas.height / depth * .47, size, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#fff'; ctx.font = `800 ${size}px Barlow Condensed, sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(site.label, screenX, horizon + canvas.height / depth * .47); ctx.globalAlpha = 1;
  }

  function renderWeapon(w, h, bob) {
    if (player.aiming && player.weapon === 'awp') return;
    const weapon = WEAPONS[player.weapon];
    const reload = player.reloading > 0 ? Math.sin((1 - player.reloading / weapon.reload) * Math.PI) : 0;
    const recoil = player.recoil * 44;
    const swayX = Math.cos(player.sway * .5) * 5;
    const gunScale = Math.max(.72, Math.min(1.05, h / 900));
    const gold = secret.discovered;
    const metal = gold ? '#967634' : '#242a2d';
    const highlight = gold ? '#d5ad4e' : '#566065';
    const dark = '#0e1112';
    const isPistol = weapon.id === 'deagle';
    const muzzleY = weapon.id === 'awp' ? -354 : isPistol ? -255 : -314;
    ctx.save();
    ctx.translate(w / 2 + swayX, h + bob - recoil + reload * 105);
    ctx.scale(gunScale, gunScale);
    ctx.rotate(reload * .38);

    // Forearms and gloves converge toward the centered grip in perspective.
    ctx.fillStyle = '#20282b';
    ctx.beginPath(); ctx.moveTo(-235, 8); ctx.lineTo(-116, -142); ctx.lineTo(-55, -118); ctx.lineTo(-104, 10); ctx.closePath(); ctx.fill();
    ctx.beginPath(); ctx.moveTo(235, 8); ctx.lineTo(116, -142); ctx.lineTo(55, -118); ctx.lineTo(104, 10); ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#111719';
    ctx.beginPath(); ctx.arc(-90, -126, 39, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(90, -126, 39, 0, Math.PI * 2); ctx.fill();

    if (isPistol) {
      ctx.fillStyle = dark;
      ctx.beginPath(); ctx.moveTo(-38, -122); ctx.lineTo(38, -122); ctx.lineTo(30, -28); ctx.lineTo(-30, -28); ctx.closePath(); ctx.fill();
      ctx.fillStyle = metal;
      ctx.beginPath(); ctx.moveTo(-63, -190); ctx.lineTo(63, -190); ctx.lineTo(48, -112); ctx.lineTo(-48, -112); ctx.closePath(); ctx.fill();
      ctx.fillStyle = highlight; ctx.fillRect(-48, -182, 96, 7);
      ctx.fillStyle = dark; ctx.fillRect(-24, -255, 48, 70);
      ctx.fillStyle = '#778186'; ctx.fillRect(-16, -250, 32, 7);
      ctx.fillStyle = dark; ctx.fillRect(-7, -269, 14, 22);
    } else {
      const wood = weapon.id === 'ak';
      ctx.fillStyle = dark;
      ctx.beginPath(); ctx.moveTo(-49, -113); ctx.lineTo(49, -113); ctx.lineTo(34, -13); ctx.lineTo(-34, -13); ctx.closePath(); ctx.fill();
      ctx.fillStyle = metal;
      ctx.beginPath(); ctx.moveTo(-112, -150); ctx.lineTo(112, -150); ctx.lineTo(81, -72); ctx.lineTo(-81, -72); ctx.closePath(); ctx.fill();
      ctx.fillStyle = '#080a0b'; ctx.fillRect(-70, -142, 140, 17);
      ctx.fillStyle = highlight; ctx.fillRect(-84, -117, 168, 8);
      ctx.fillStyle = wood && !gold ? '#89572b' : metal;
      ctx.beginPath(); ctx.moveTo(-72, -232); ctx.lineTo(72, -232); ctx.lineTo(105, -149); ctx.lineTo(-105, -149); ctx.closePath(); ctx.fill();
      ctx.fillStyle = wood && !gold ? '#b07839' : highlight;
      ctx.beginPath(); ctx.moveTo(-57, -220); ctx.lineTo(57, -220); ctx.lineTo(64, -202); ctx.lineTo(-64, -202); ctx.closePath(); ctx.fill();
      ctx.fillStyle = dark; ctx.fillRect(-18, muzzleY, 36, 126);
      ctx.fillStyle = '#50595d'; ctx.fillRect(-10, muzzleY + 7, 20, 105);
      ctx.fillStyle = dark; ctx.fillRect(-6, muzzleY - 18, 12, 28);
      ctx.strokeStyle = '#798287'; ctx.lineWidth = 3; ctx.beginPath(); ctx.moveTo(0, -122); ctx.lineTo(0, muzzleY + 26); ctx.stroke();
      if (weapon.id === 'awp') {
        ctx.fillStyle = '#0a0d0e'; ctx.beginPath(); ctx.arc(0, -181, 58, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = '#253f48'; ctx.beginPath(); ctx.arc(0, -181, 44, 0, Math.PI * 2); ctx.fill();
        ctx.strokeStyle = '#7296a1'; ctx.lineWidth = 3; ctx.beginPath(); ctx.arc(0, -181, 39, 0, Math.PI * 2); ctx.stroke();
        ctx.strokeStyle = '#9cb4bb55'; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(-30, -181); ctx.lineTo(30, -181); ctx.moveTo(0, -211); ctx.lineTo(0, -151); ctx.stroke();
      } else {
        ctx.fillStyle = dark; ctx.beginPath(); ctx.moveTo(-11, -250); ctx.lineTo(11, -250); ctx.lineTo(7, -218); ctx.lineTo(-7, -218); ctx.closePath(); ctx.fill();
      }
    }
    if (muzzle > 0) {
      const flash = weapon.id === 'awp' ? 70 : 48;
      ctx.fillStyle = '#ffd36b'; ctx.beginPath(); ctx.moveTo(0, muzzleY - flash); ctx.lineTo(15, muzzleY - 12); ctx.lineTo(flash, muzzleY - 4); ctx.lineTo(16, muzzleY + 9); ctx.lineTo(0, muzzleY + flash * .55); ctx.lineTo(-16, muzzleY + 9); ctx.lineTo(-flash, muzzleY - 4); ctx.lineTo(-15, muzzleY - 12); ctx.closePath(); ctx.fill();
      ctx.fillStyle = '#fff7d1'; ctx.beginPath(); ctx.arc(0, muzzleY - 2, 13, 0, Math.PI * 2); ctx.fill();
      ctx.strokeStyle = '#ffd88a99'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(0, muzzleY - 5); ctx.lineTo(0, -h / gunScale + h / 2 / gunScale); ctx.stroke();
    }
    ctx.restore();

    if (hitmarker > 0) {
      ctx.strokeStyle = lastHeadshot ? `rgba(255,196,90,${hitmarker / .15})` : `rgba(255,255,255,${hitmarker / .15})`; ctx.lineWidth = 2;
      const cx = w / 2, cy = h / 2; ctx.beginPath();
      ctx.moveTo(cx - 13, cy - 13); ctx.lineTo(cx - 5, cy - 5); ctx.moveTo(cx + 13, cy - 13); ctx.lineTo(cx + 5, cy - 5);
      ctx.moveTo(cx - 13, cy + 13); ctx.lineTo(cx - 5, cy + 5); ctx.moveTo(cx + 13, cy + 13); ctx.lineTo(cx + 5, cy + 5); ctx.stroke();
    }
  }

  function renderRadar() {
    const w = radar.width, h = radar.height;
    rctx.clearRect(0, 0, w, h); rctx.fillStyle = '#0b1013e8'; rctx.fillRect(0, 0, w, h);
    const scale = Math.min((w - 20) / MAP_W, (h - 18) / MAP_H);
    const ox = (w - MAP_W * scale) / 2, oy = (h - MAP_H * scale) / 2;
    for (let y = 0; y < MAP_H; y++) for (let x = 0; x < MAP_W; x++) {
      rctx.fillStyle = grid[y][x] ? (grid[y][x] === 3 ? '#554837' : '#342f28') : '#b5a37b30';
      rctx.fillRect(ox + x * scale, oy + y * scale, scale + .2, scale + .2);
    }
    for (const [label, site] of Object.entries(sites)) {
      rctx.fillStyle = '#c57443aa'; rctx.beginPath(); rctx.arc(ox + site.x * scale, oy + site.y * scale, site.radius * scale, 0, Math.PI * 2); rctx.fill();
      rctx.fillStyle = '#fff'; rctx.font = 'bold 12px Inter'; rctx.textAlign = 'center'; rctx.fillText(label, ox + site.x * scale, oy + site.y * scale + 4);
    }
    if (bomb.state !== 'carried' || bomb.carrier) {
      const bx = (bomb.carrier?.x ?? bomb.x), by = (bomb.carrier?.y ?? bomb.y);
      rctx.fillStyle = '#ffbb45'; rctx.fillRect(ox + bx * scale - 3, oy + by * scale - 3, 6, 6);
    }
    for (const bot of bots) {
      if (!bot.alive) continue;
      rctx.fillStyle = bot.team === 'CT' ? '#75b5e7' : '#dd765c';
      rctx.beginPath(); rctx.arc(ox + bot.x * scale, oy + bot.y * scale, 2.6, 0, Math.PI * 2); rctx.fill();
    }
    rctx.save(); rctx.translate(ox + player.x * scale, oy + player.y * scale); rctx.rotate(player.angle);
    rctx.fillStyle = '#fff'; rctx.beginPath(); rctx.moveTo(7, 0); rctx.lineTo(-5, -4); rctx.lineTo(-3, 0); rctx.lineTo(-5, 4); rctx.closePath(); rctx.fill(); rctx.restore();
    rctx.fillStyle = '#ffffff90'; rctx.font = '600 9px Inter'; rctx.textAlign = 'left'; rctx.fillText('DUSTLINE', 9, 13);
  }

  function updateHud() {
    ui.scope.hidden = !(player.aiming && player.weapon === 'awp' && player.alive && state === 'playing');
    const crosshair = document.querySelector('.crosshair');
    if (crosshair) crosshair.hidden = !ui.scope.hidden || !player.alive;
    ui.alive.textContent = `CT ${bots.filter(b => b.alive && b.team === 'CT').length + Number(player.alive)}  /  ${bots.filter(b => b.alive && b.team === 'T').length} T · FIRST TO 5`;
    if (!ui.scoreboard.hidden) ui.scoreRows.innerHTML = [player, ...bots].map(b => `<tr class="${b.team.toLowerCase()} ${b.alive ? '' : 'dead'} ${b === player ? 'you' : ''}"><td>${b.name}</td><td>${b.alive ? 'ACTIVE' : 'DOWN'}</td><td>${b.kills}</td><td>${b.deaths}</td></tr>`).join('');
    ui.health.textContent = Math.max(0, Math.ceil(player.health)); ui.armor.textContent = Math.ceil(player.armor);
    ui.ammo.textContent = player.reloading ? '··' : player.ammo; ui.reserve.textContent = player.reserve;
    const shown = bomb.state === 'planted' ? Math.max(0, bomb.timer) : Math.max(0, roundTime);
    const minutes = Math.floor(shown / 60), seconds = Math.floor(shown % 60);
    ui.timer.textContent = `${minutes}:${seconds.toString().padStart(2, '0')}`;
    ui.timer.style.color = shown < 11 ? '#e16656' : '#fff';
    ui.hudMoney.textContent = `$${money.toLocaleString()}`;
    if (!ui.buyMenu.hidden) updateBuyMenu();
  }

  function initAudio() {
    try {
      const Audio = window.AudioContext || window.webkitAudioContext;
      if (!Audio) return;
      if (!audio) audio = new Audio();
      audio.resume()?.catch?.(() => {});
    } catch { audio = null; }
  }

  function tone(freq, duration, type = 'square', gain = .035, slide = 0) {
    if (!audio) return;
    const osc = audio.createOscillator(), vol = audio.createGain();
    osc.type = type; osc.frequency.setValueAtTime(freq, audio.currentTime);
    if (slide) osc.frequency.exponentialRampToValueAtTime(Math.max(20, freq + slide), audio.currentTime + duration);
    vol.gain.setValueAtTime(gain * volume, audio.currentTime); vol.gain.exponentialRampToValueAtTime(.0001, audio.currentTime + duration);
    osc.connect(vol).connect(audio.destination); osc.start(); osc.stop(audio.currentTime + duration);
  }

  function sound(name) {
    if (name === 'shot') { tone(120, .07, 'sawtooth', .09, -75); tone(54, .11, 'square', .055, -20); }
    else if (name === 'hit') tone(680, .045, 'square', .025, 120);
    else if (name === 'empty') tone(190, .035, 'square', .02, -20);
    else if (name === 'reload') { tone(240, .05, 'triangle', .02, -80); setTimeout(() => tone(310, .06, 'triangle', .018, 70), 900); }
    else if (name === 'beep') tone(950, .08, 'square', .035, 10);
    else if (name === 'plant') { tone(420, .12, 'square', .04, 180); setTimeout(() => tone(650, .16, 'square', .04, 100), 120); }
    else if (name === 'explosion') { tone(70, .8, 'sawtooth', .16, -45); tone(42, 1.2, 'square', .12, -20); }
    else if (name === 'death') tone(180, .5, 'sawtooth', .05, -130);
    else if (name === 'win') { tone(440, .18, 'triangle', .035, 150); setTimeout(() => tone(660, .3, 'triangle', .035, 220), 170); }
    else if (name === 'loss') tone(240, .45, 'sawtooth', .035, -120);
  }

  function playBotShot(bot) {
    if (!audio) return;
    const d = distance(player, bot); tone(95 + Math.random() * 30, .055, 'sawtooth', Math.max(.006, .055 - d * .003), -50);
  }

  function frame(now) {
    visualTime = now / 1000;
    const dt = Math.min(.05, (now - lastTime) / 1000 || 0); lastTime = now;
    if (state === 'playing') {
      updatePlayer(dt); bots.forEach((bot) => updateBot(bot, dt));
    } else {
      player.recoil = Math.max(0, player.recoil - dt); muzzle = Math.max(0, muzzle - dt); shake *= Math.pow(.02, dt);
    }
    updateRound(dt, now); renderWorld(); renderRadar(); updateHud();
    requestAnimationFrame(frame);
  }

  function captureMouse() {
    try { canvas.requestPointerLock?.()?.catch?.(() => { pauseState = state; state = 'paused'; ui.pause.hidden = false; }); } catch { pauseState = state; state = 'paused'; ui.pause.hidden = false; }
  }
  function startMatch() {
    initAudio(); started = true; ui.menu.hidden = true; ui.result.hidden = true; ui.hud.setAttribute('aria-hidden', 'false');
    ctScore = 0; tScore = 0; money = 8000; player.weapon = 'm4'; player.kills = 0; player.deaths = 0; bots = [];
    ui.ctScore.textContent = '0'; ui.tScore.textContent = '0'; roundNumber = 0; startRound(); captureMouse();
  }
  ui.play.addEventListener('click', startMatch);
  $('#classic-play-again').addEventListener('click', startMatch);
  ui.resume.addEventListener('click', () => { initAudio(); captureMouse(); });
  document.addEventListener('pointerlockchange', () => {
    if (!started) return;
    const locked = document.pointerLockElement === canvas;
    if (locked) { ui.pause.hidden = true; if (state === 'paused') state = pauseState; }
    else if (state === 'playing' || state === 'roundover') { pauseState = state; state = 'paused'; ui.pause.hidden = false; player.firing = false; player.aiming = false; keys = Object.create(null); }
  });
  document.addEventListener('mousemove', event => {
    if (document.pointerLockElement !== canvas || !player.alive || state !== 'playing') return;
    const slow = player.aiming ? .42 : 1;
    player.angle += event.movementX * .00225 * sensitivity * slow;
    player.pitch = Math.max(-canvas.height * .35, Math.min(canvas.height * .35, player.pitch - event.movementY * .72 * sensitivity * slow));
  });
  document.addEventListener('keydown', event => {
    if (event.target?.tagName === 'INPUT') return;
    if (event.code === 'Tab' && started) { event.preventDefault?.(); ui.scoreboard.hidden = false; }
    keys[event.code] = true;
    if (event.repeat) return;
    if (event.code === 'KeyR') startReload();
    if (event.code === 'KeyF' && state === 'playing') trySecret();
    if (event.code === 'KeyB') toggleBuyMenu();
    if (event.code === 'KeyC' && !player.alive) spectatorIndex++;
    if (buySlots[event.code]) buyWeapon(buySlots[event.code]);
  });
  document.addEventListener('keyup', event => { keys[event.code] = false; if (event.code === 'Tab') ui.scoreboard.hidden = true; });
  document.addEventListener('mousedown', event => {
    if (state !== 'playing' || !player.alive) return;
    if (document.pointerLockElement !== canvas) { if (event.target === canvas) captureMouse(); return; }
    if (event.button === 2) player.aiming = true;
    if (event.button === 0) { player.firing = true; playerShoot(); }
  });
  document.addEventListener('mouseup', event => { if (event.button === 0) player.firing = false; if (event.button === 2) player.aiming = false; });
  document.addEventListener('contextmenu', event => event.preventDefault?.());
  function loseFocus() {
    keys = Object.create(null); player.firing = false; player.aiming = false; ui.scoreboard.hidden = true;
    if (state === 'playing' || state === 'roundover' || state === 'buying') { pauseState = state === 'buying' ? 'playing' : state; state = 'paused'; ui.buyMenu.hidden = true; ui.pause.hidden = false; document.exitPointerLock?.(); }
  }
  window.addEventListener('blur', loseFocus);
  document.addEventListener('visibilitychange', () => { if (document.hidden) loseFocus(); });
  for (const card of ui.buyMenu.querySelectorAll?.('[data-slot]') || []) {
    card.setAttribute('role', 'button'); card.setAttribute('tabindex', '0');
    card.addEventListener('click', () => buyWeapon(buySlots['Digit' + card.dataset.slot]));
    card.addEventListener('keydown', event => { if (event.code === 'Enter' || event.code === 'Space') { event.preventDefault(); buyWeapon(buySlots['Digit' + card.dataset.slot]); } });
  }
  for (const [id, name] of [['classic-sensitivity', 'sensitivity'], ['classic-volume', 'volume']]) {
    const input = $('#' + id); input.value = name === 'sensitivity' ? sensitivity : volume;
    input.addEventListener('input', () => { if (name === 'sensitivity') sensitivity = Number(input.value); else volume = Number(input.value); try { localStorage.setItem('desert-strike-classic', JSON.stringify({ sensitivity, volume })); } catch {} });
  }
  window.addEventListener('resize', resize);

  resize(); resetBots();
  window.DesertStrike = Object.freeze({
    version: '0.3.0',
    map: grid.map((row) => [...row]),
    sites: Object.fromEntries(Object.entries(sites).map(([name, site]) => [name, { ...site }])),
    spawns: { CT: [[16.2, 3.8], ...ctSpawns], T: tSpawns.map((spawn) => [...spawn]) },
    getState: () => ({ state, roundTime, roundNumber, ctScore, tScore, bombState: bomb.state, playerPitch: player.pitch, playerAngle: player.angle, x: player.x, y: player.y, health: player.health, ammo: player.ammo, reserve: player.reserve, reloading: player.reloading, aiming: player.aiming, kills: player.kills, deaths: player.deaths, weapon: player.weapon, money })
  });
  if (demoMode) {
    started = true; ui.menu.hidden = true; ui.hud.setAttribute('aria-hidden', 'false');
    roundNumber = 0; startRound();
  }
  requestAnimationFrame(frame);
})();
