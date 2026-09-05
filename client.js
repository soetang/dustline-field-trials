(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const canvas = $('bevy-canvas');
  const touchMode = !!window.matchMedia?.('(pointer: coarse)').matches || Number(navigator.maxTouchPoints) > 0 || /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
  let touch = null;
  const prices = [3100, 2700, 4750, 700], magazines = [30, 30, 10, 7];
  const ui = { started: false, paused: true, shop: false, screenshot: false, ready: false, commands: [], sensitivity: 1, volume: .6, quality: touchMode ? 'low' : 'standard', seed: Math.floor(Math.random() * 0xffffffff) || 1 };
  let held = {}, lookX = 0, lookY = 0, firePressed = false, reloadPressed = false;
  let state = null, previous = null, feedKey = '', scoreKey = '', mapDrawn = false;
  let audio = null, master = null, noise = null, nextBeep = 0, stepDistance = 0, lastPosition = null;
  try {
    const settings = JSON.parse(localStorage.getItem('desert-strike-settings') || '{}');
    ui.sensitivity = Math.min(2.5, Math.max(.3, Number(settings.sensitivity) || 1));
    ui.volume = Number.isFinite(settings.volume) ? Math.min(1, Math.max(0, settings.volume)) : .6;
    if (['low','standard'].includes(settings.quality)) ui.quality = settings.quality;
  } catch { /* Storage is optional, including in private browser sessions. */ }
  const text = (id, value) => { const node = $(id); const content = String(value); if (node.textContent !== content) node.textContent = content; };
  const show = (id, visible) => { $(id).hidden = !visible; };
  const clock = seconds => `${Math.floor(Math.max(0, Math.ceil(seconds)) / 60)}:${String(Math.max(0, Math.ceil(seconds)) % 60).padStart(2, '0')}`;
  const money = amount => '$' + amount.toLocaleString('en-US');
  const active = () => ui.started && !ui.paused && !document.hidden && (touchMode || document.pointerLockElement === canvas || ui.shop);
  const clearInput = () => { held = {}; lookX = 0; lookY = 0; firePressed = false; reloadPressed = false; touch?.reset(); };
  const showTouch = () => { show('touch-controls', touchMode && active() && !ui.shop && !ui.screenshot && state?.phase !== 'finished'); };

  function saveSettings() {
    try { localStorage.setItem('desert-strike-settings', JSON.stringify({ sensitivity: ui.sensitivity, volume: ui.volume, quality: ui.quality })); } catch {}
  }
  function initAudio() {
    try {
      if (!audio) {
        const Audio = window.AudioContext || window.webkitAudioContext;
        if (!Audio) return;
        audio = new Audio(); master = audio.createGain(); master.gain.value = ui.volume; master.connect(audio.destination);
        noise = audio.createBuffer(1, audio.sampleRate * 2, audio.sampleRate);
        const data = noise.getChannelData(0); for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
      }
      audio.resume().catch(() => {});
    } catch { audio = null; }
  }
  function tone(frequency, duration, volume = .12, type = 'sine', delay = 0, end = frequency) {
    if (!audio || audio.state !== 'running') return;
    const start = audio.currentTime + delay, osc = audio.createOscillator(), gain = audio.createGain();
    osc.type = type; osc.frequency.setValueAtTime(frequency, start); osc.frequency.exponentialRampToValueAtTime(Math.max(10, end), start + duration);
    gain.gain.setValueAtTime(volume, start); gain.gain.exponentialRampToValueAtTime(.001, start + duration);
    osc.connect(gain).connect(master); osc.start(start); osc.stop(start + duration + .01);
  }
  function burst(duration = .12, volume = .28, cutoff = 2200) {
    if (!audio || audio.state !== 'running' || !noise) return;
    const src = audio.createBufferSource(), filter = audio.createBiquadFilter(), gain = audio.createGain();
    src.buffer = noise; filter.type = 'lowpass'; filter.frequency.value = cutoff;
    gain.gain.setValueAtTime(volume, audio.currentTime); gain.gain.exponentialRampToValueAtTime(.001, audio.currentTime + duration);
    src.connect(filter).connect(gain).connect(master); src.start(0, Math.random()); src.stop(audio.currentTime + duration + .01);
  }
  async function capture() {
    screenshotView(false);
    clearInput();
    initAudio(); ui.paused = false; ui.shop = false; show('pause', false); show('buy-menu', false);
    if (touchMode) { showTouch(); return; }
    canvas.focus({ preventScroll: true });
    try { await canvas.requestPointerLock(); } catch { pause(); text('pause-heading', 'CLICK TO REJOIN.'); }
  }
  function pause() {
    if (!ui.started || state?.phase === 'finished') return;
    clearInput();
    ui.paused = true; ui.shop = false; show('buy-menu', false); show('scoreboard', false); show('pause', !ui.screenshot);
    showTouch();
    if (document.pointerLockElement) document.exitPointerLock();
  }
  function screenshotView(enabled) {
    ui.screenshot = enabled;
    document.body.classList.toggle('screenshot-view', enabled);
    show('screenshot-exit', enabled);
  }
  function toggleScreenshot() {
    if (!ui.started || state?.phase === 'finished') return;
    screenshotView(!ui.screenshot);
    // Remain paused even when a snipping tool blurs/hides the browser. Closing
    // this view returns to the menu; it must never silently resume combat.
    pause();
    (ui.screenshot ? $('screenshot-exit') : $('resume')).focus({ preventScroll: true });
  }
  function deploy(restart = false) {
    if (!ui.ready) return;
    if (restart) ui.seed = Math.floor(Math.random() * 0xffffffff) || 1;
    ui.started = true; ui.commands.push(restart ? 'restart' : 'start');
    show('front-menu', false); show('match-end', false); show('bevy-hud', true); show('round-end', false);
    document.body.classList.remove('in-menu'); capture();
  }
  function shop() {
    if (!ui.started || ui.paused || !state || state.health <= 0 || !['buy', 'live'].includes(state.phase)) return;
    if (ui.shop) { capture(); return; }
    clearInput();
    ui.shop = true; show('buy-menu', true); if (document.pointerLockElement) document.exitPointerLock();
    showTouch();
    $('close-buy').focus({ preventScroll: true });
  }

  $('deploy').addEventListener('click', () => deploy());
  $('resume').addEventListener('click', () => capture());
  $('restart').addEventListener('click', () => deploy(true));
  $('play-again').addEventListener('click', () => deploy(true));
  $('close-buy').addEventListener('click', () => capture());
  $('screenshot-mode').addEventListener('click', toggleScreenshot);
  $('screenshot-exit').addEventListener('click', toggleScreenshot);
  function diagnostics() {
    return [
      'Dustline: Field Trials test details',
      `Page: ${location.origin}${location.pathname}`,
      `Build: ${window.desertStrike.release || 'not loaded'}`,
      `Match seed: ${state?.seed ?? ui.seed}; graphics: ${ui.quality}; input: ${touchMode ? 'touch' : 'mouse'}`,
      `Map: ${state?.map[0].length || '?'} × ${state?.map.length || '?'} metres`,
      `Browser: ${navigator.userAgent}`,
      `Canvas: ${canvas.width} × ${canvas.height}; recent frame: ${state?.fps.toFixed(1) || '?'} FPS`,
      state ? `Round: ${state.round} (${state.phase}); position: ${state.x.toFixed(1)}, ${state.z.toFixed(1)}; HP: ${Math.ceil(state.health)}; weapon: ${state.weapon}` : 'Game state unavailable',
      `View: yaw ${Number.isFinite(state?.yaw) ? (state.yaw * 180 / Math.PI).toFixed(1) : '?'}°; pitch ${Number.isFinite(state?.pitch) ? (state.pitch * 180 / Math.PI).toFixed(1) : '?'}°; ground ${state?.elevation?.toFixed(2) ?? '?'}m; aiming ${state?.aiming ? 'yes' : 'no'}`,
      'What I did: ', 'What I expected: ', 'What happened: ',
    ].join('\n');
  }
  $('copy-feedback').addEventListener('click', async () => {
    const report = diagnostics();
    $('test-details').value = report; show('test-details', true);
    try {
      await navigator.clipboard.writeText(report);
      text('copy-feedback', 'COPIED — PASTE INTO CHAT');
    } catch {
      $('test-details').focus(); $('test-details').select();
      text('copy-feedback', 'SELECTED — COPY AND PASTE INTO CHAT');
    }
  });
  document.querySelectorAll('[data-slot]').forEach(button => button.addEventListener('click', () => {
    if (ui.shop && !button.disabled) ui.commands.push(`buy${button.dataset.slot}`);
  }));
  document.addEventListener('pointerlockchange', () => {
    if (touchMode) return;
    if (document.pointerLockElement !== canvas && !ui.shop && ui.started) pause();
    else if (document.pointerLockElement === canvas) { ui.paused = false; show('pause', false); }
  });
  document.addEventListener('pointerlockerror', () => { if (!touchMode && ui.started && !ui.shop) pause(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  window.addEventListener('blur', () => {
    // Mobile browser chrome can transiently take focus without hiding the game.
    // Always release controls, but use visibility/pagehide for mobile pausing.
    clearInput();
    if (!touchMode || document.hidden) pause();
  });
  window.addEventListener('pagehide', pause);
  window.addEventListener('contextmenu', event => event.preventDefault());
  document.addEventListener('keydown', event => {
    if (active() && !ui.shop && event.target.tagName !== 'INPUT') {
      held[event.code] = true;
      if (event.code === 'KeyR' && !event.repeat) reloadPressed = true;
      if (event.code === 'KeyC' && !event.repeat && state?.health <= 0) ui.commands.push('spectate');
    }
    if (event.code === 'Tab' && ui.started && !ui.paused && !ui.shop) { event.preventDefault(); show('scoreboard', true); }
    if (event.repeat || ['INPUT', 'TEXTAREA'].includes(event.target.tagName)) return;
    if (event.code === 'F8' && ui.started) { event.preventDefault(); toggleScreenshot(); return; }
    if (event.code === 'KeyB') { event.preventDefault(); shop(); }
    if (event.code === 'Escape' && ui.started) { if (ui.screenshot) toggleScreenshot(); else pause(); }
    if (ui.shop && /^Digit[1-4]$/.test(event.code)) { event.preventDefault(); ui.commands.push(`buy${Number(event.code.slice(-1)) - 1}`); }
  }, true);
  document.addEventListener('keyup', event => { if (Object.hasOwn(held, event.code)) held[event.code] = false; if (event.code === 'Tab') show('scoreboard', false); }, true);
  document.addEventListener('mousemove', event => { if (active() && !ui.shop) { lookX += event.movementX; lookY += event.movementY; } });
  document.addEventListener('mousedown', event => {
    if (!active() || ui.shop || document.pointerLockElement !== canvas) return;
    if (event.button === 0) { held.fire = true; firePressed = true; }
    if (event.button === 2) held.aim = true;
  });
  document.addEventListener('mouseup', event => { if (event.button === 0) held.fire = false; if (event.button === 2) held.aim = false; });
  for (const id of ['sensitivity', 'volume']) {
    $(id).value = ui[id];
    const update = () => {
      ui[id] = Number($(id).value); text(`${id}-value`, id === 'volume' ? `${Math.round(ui.volume * 100)}%` : ui.sensitivity.toFixed(1));
      if (master) master.gain.value = ui.volume; saveSettings();
    };
    $(id).addEventListener('input', update); update();
  }
  $('quality').value = ui.quality;
  $('quality').addEventListener('change', () => { ui.quality = $('quality').value === 'low' ? 'low' : 'standard'; saveSettings(); });
  document.body.classList.toggle('touch-mode', touchMode);
  touch = window.createDustlineTouchControls?.({enabled: touchMode, active: () => active() && !ui.shop,
    pause, shop, reload: () => { reloadPressed = true; }, spectate: () => { if (state?.health <= 0) ui.commands.push('spectate'); }});

  function drawMap(target, s, briefing = false) {
    const ctx = target.getContext('2d'), w = target.width, h = target.height;
    const mapW = s.map[0].length, mapH = s.map.length, scale = Math.min(w / (mapW + 8), h / (mapH + 8));
    const ox = (w - mapW * scale) / 2, oz = (h - mapH * scale) / 2;
    const sites = s.sites || [[5.8, 4.4], [26.1, 4.8]], spawn = s.spawn || [16.2, 3.8];
    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = '#abc89b0a'; ctx.lineWidth = 1;
    for (let x = 0; x < w; x += scale * 2) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke(); }
    for (let z = 0; z < h; z += scale * 2) { ctx.beginPath(); ctx.moveTo(0, z); ctx.lineTo(w, z); ctx.stroke(); }
    s.map.forEach((row, z) => row.forEach((tile, x) => {
      if (tile === 1) return;
      ctx.fillStyle = tile ? '#69725b' : '#455a48'; ctx.fillRect(ox + x * scale, oz + z * scale, scale - .4, scale - .4);
    }));
    ctx.font = `bold ${briefing ? 16 : 10}px Arial`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    for (const [index, [x, z]] of sites.entries()) {
      ctx.fillStyle = '#e3b35b24'; ctx.beginPath(); ctx.arc(ox + x * scale, oz + z * scale, 2 * scale, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#efd098'; ctx.fillText(index === 0 ? 'A' : 'B', ox + x * scale, oz + z * scale);
    }
    if (briefing) {
      ctx.fillStyle = '#83c8c7'; ctx.font = '8px monospace'; ctx.fillText('CT', ox + spawn[0] * scale, oz + spawn[1] * scale);
      const attacker = s.attackerSpawn || [16, 22];
      ctx.fillStyle = '#e3b35b'; ctx.fillText('T', ox + attacker[0] * scale, oz + attacker[1] * scale); return;
    }
    for (const bot of s.bots) {
      if (bot.health <= 0 || (bot.team === 'T' && bot.spotted <= 0)) continue;
      ctx.fillStyle = bot.team === 'CT' ? '#83c8c7' : '#ed8a60'; ctx.beginPath(); ctx.arc(ox + bot.x * scale, oz + bot.z * scale, 2.4, 0, Math.PI * 2); ctx.fill();
    }
    if (s.health > 0) {
      ctx.save(); ctx.translate(ox + s.x * scale, oz + s.z * scale); ctx.rotate(-s.yaw);
      ctx.fillStyle = '#f6f5d9'; ctx.beginPath(); ctx.moveTo(0, -5); ctx.lineTo(-3.5, 4); ctx.lineTo(0, 2); ctx.lineTo(3.5, 4); ctx.closePath(); ctx.fill();
      ctx.fillStyle = '#f6f5d910'; ctx.beginPath(); ctx.moveTo(0, 0); ctx.arc(0, 0, 27, -Math.PI * .73, -Math.PI * .27); ctx.closePath(); ctx.fill(); ctx.restore();
    }
    if (['planted', 'dropped'].includes(s.bomb.state)) {
      ctx.fillStyle = s.bomb.state === 'planted' ? '#ff704c' : '#f4d497'; ctx.fillRect(ox + s.bomb.x * scale - 3, oz + s.bomb.z * scale - 3, 6, 6);
    }
  }
  function renderFeed(s) {
    const key = JSON.stringify(s.feed); if (key === feedKey) return; feedKey = key;
    $('killfeed').replaceChildren(...s.feed.map(item => {
      const row = document.createElement('div'); row.className = 'feed-row';
      const killer = document.createElement('span'), icon = document.createElement('i'), victim = document.createElement('span');
      killer.textContent = item.killer; killer.className = item.ct ? 'ct-name' : 't-name';
      victim.textContent = item.victim; victim.className = item.ct ? 't-name' : 'ct-name'; icon.textContent = item.headshot ? '⌖' : '→';
      row.append(killer, icon, victim); return row;
    }));
  }
  function renderScores(s) {
    const rows = [{ name: 'YOU', team: 'CT', health: s.health, kills: s.kills, deaths: s.deaths }, ...s.bots];
    const key = rows.map(r => `${r.health > 0}:${r.kills}:${r.deaths}:${r.team === 'CT' ? r.intent : ''}`).join('|'); if (scoreKey === key) return; scoreKey = key;
    $('score-rows').replaceChildren(...rows.map(r => {
      const row = document.createElement('tr'); row.className = `${r.team === 'CT' ? 'ct-row' : 't-row'} ${r.name === 'YOU' ? 'you-row' : ''} ${r.health <= 0 ? 'dead-row' : ''}`;
      for (const value of [r.name, r.health > 0 ? (r.team === 'CT' && r.intent ? r.intent : 'ACTIVE') : 'ELIMINATED', r.kills, r.deaths]) { const cell = document.createElement('td'); cell.textContent = value; row.append(cell); }
      return row;
    }));
  }
  function renderAudio(s) {
    if (!active()) return;
    if (previous && s.shots > previous.shots) { burst(s.slot === 2 ? .35 : .13, s.slot === 2 ? .65 : .36, s.slot === 3 ? 1500 : 3200); tone(150, .14, .22, 'triangle', 0, 38); }
    if (previous && s.hurts > previous.hurts) { burst(.1, .2, 500); tone(85, .15, .1, 'sine', 0, 40); }
    if (previous && s.hitmarker > previous.hitmarker) { tone(s.headshot ? 1400 : 950, .045, .08, 'triangle'); }
    if (previous && s.eliminations > previous.eliminations) { tone(640, .1, .06); tone(960, .15, .05, 'sine', .08); }
    if (previous && s.reload > 0 && previous.reload === 0) { burst(.07, .15, 3500); tone(260, .1, .05, 'square', .12); }
    if (previous && s.reload === 0 && previous.reload > 0) burst(.06, .18, 4000);
    if (previous && s.phase !== previous.phase) {
      if (s.phase === 'live') { tone(480, .13, .08); tone(720, .2, .1, 'sine', .15); }
      if (['end', 'finished'].includes(s.phase)) {
        const notes = s.winner === 'CT' ? [440, 554, 660] : [330, 294, 220]; notes.forEach((f, i) => tone(f, .5, .12, 'triangle', i * .16));
        if (s.bomb.state === 'exploded') { burst(1., .7, 420); tone(65, .9, .35, 'sine', 0, 15); }
      }
    }
    if (s.bomb.state === 'planted' && performance.now() > nextBeep) {
      tone(1800, .055, .055); nextBeep = performance.now() + Math.max(110, s.bomb.time * 32);
    }
    if (lastPosition && s.moving && s.health > 0) {
      stepDistance += Math.hypot(s.x - lastPosition[0], s.z - lastPosition[1]);
      if (stepDistance > 1.1) { burst(.055, .075, 600); stepDistance = 0; }
    }
    lastPosition = [s.x, s.z];
    if (previous) s.bots.forEach((bot, i) => {
      if (bot.flash > 0 && previous.bots[i].flash <= 0 && Math.hypot(bot.x - s.x, bot.z - s.z) < 14) burst(.07, .06, 1000);
    });
  }

  function render(s) {
    if (!ui.ready) {
      ui.ready = true; $('loading').remove(); show('front-menu', true);
      window.dispatchEvent(new Event('desert-strike-ready'));
    }
    if (!mapDrawn) { drawMap($('brief-map'), s, true); mapDrawn = true; }
    state = s;
    showTouch();
    show('touch-spectate', s.health <= 0);
    const roundLive = s.phase === 'live' && s.time > 87.5;
    show('round-announcement', s.phase === 'buy' || roundLive);
    $('round-announcement').classList.toggle('round-live', roundLive);
    text('round-cue-label', roundLive ? 'ROUND LIVE' : `ROUND ${s.round} · PREPARATION`);
    text('round-cue-time', roundLive ? 'GO' : Math.max(1, Math.ceil(s.phaseTime)));
    text('round-cue-detail', roundLive ? 'Movement unlocked · defend A & B' : `Movement locked · ${touchMode ? 'tap BUY' : 'B'} to choose your loadout`);
    text('health', Math.ceil(s.health)); text('armor', Math.ceil(s.armor)); text('money', money(s.money)); text('buy-money', money(s.money));
    text('ammo', s.ammo); text('reserve', s.reserve); text('weapon-name', s.weapon); text('weapon-class', ['ASSAULT RIFLE', 'ASSAULT RIFLE', 'PRECISION RIFLE', 'HEAVY PISTOL'][s.slot]); text('weapon-slot', `0${s.slot + 1}`);
    text('ct-score', s.scores[0]); text('t-score', s.scores[1]); text('round-label', `ROUND ${String(s.round).padStart(2, '0')}`);
    text('ct-alive', '●'.repeat(s.alive[0]) + '○'.repeat(5 - s.alive[0])); text('t-alive', '●'.repeat(s.alive[1]) + '○'.repeat(5 - s.alive[1]));
    const planted = s.bomb.state === 'planted';
    text('round-time', clock(planted ? s.bomb.time : s.phase === 'buy' ? s.phaseTime : s.time));
    text('phase-label', planted ? 'BOMB ACTIVE' : s.phase === 'buy' ? 'PREPARE' : 'FIRST TO 5');
    text('objective', planted ? `BOMB PLANTED AT ${s.bomb.site} · RETAKE THE SITE` : s.phase === 'buy' ? 'PREPARE YOUR LOADOUT · B TO BUY' : 'DEFEND A & B · ELIMINATE THE ATTACKERS');
    text('notice', s.notice); text('purchase-notice', s.notice);
    const layoutScale = s.layoutScale || 1, lx = s.x / layoutScale, lz = s.z / layoutScale;
    text('location', lz < 8 ? (lx < 12 ? 'A SITE' : lx > 22 ? 'B SITE' : 'CT SPAWN') : lx < 8 ? 'LONG A' : lx > 22 ? 'B TUNNELS' : lz > 18 ? 'T SPAWN' : 'MID');
    text('radar-status', `${s.alive[0]} FRIENDLIES · ${s.alive[1]} HOSTILES`);
    $('health-bar').style.width = `${s.health}%`;
    $('ammo-bar').style.width = `${100 * (s.reload > 0 ? 1 - s.reload / s.reloadTime : s.ammo / magazines[s.slot])}%`;
    text('reload-hint', s.reload > 0 ? `RELOADING ${s.reload.toFixed(1)}s` : s.ammo === 0 ? 'R · RELOAD' : '');
    text('buy-hint', s.buyTime > 0 ? `B · LOADOUT ${Math.ceil(s.buyTime)}s` : 'BUY PERIOD CLOSED');
    text('buy-time', `${Math.ceil(s.buyTime)} SECONDS REMAINING`);
    const spawn = s.spawn || [16.2, 3.8];
    const inBuyZone = Math.hypot(s.x - spawn[0], s.z - spawn[1]) <= 4.5;
    text('buy-status', s.buyTime <= 0 ? 'Buy period has ended. Your current weapon is equipped.' : !inBuyZone ? 'Return to CT spawn to purchase a weapon.' : 'Choose your primary weapon. Press 1–4 or click to purchase.');
    document.querySelectorAll('[data-slot]').forEach(button => {
      const slot = Number(button.dataset.slot); button.disabled = s.money < prices[slot] || s.buyTime <= 0 || !inBuyZone || s.health <= 0;
      button.classList.toggle('equipped', slot === s.slot); button.setAttribute('aria-label', `${['M4A4', 'AK-47', 'AWP', 'Desert Eagle'][slot]}, ${money(prices[slot])}${slot === s.slot ? ', equipped' : ''}`);
    });
    document.body.classList.toggle('bomb-live', planted); document.body.classList.toggle('low-health', s.health < 35);
    const spreadGap = s.spread === undefined ? s.recoil * 10 + (s.moving ? 5 : 0) : Math.min(28, s.spread * 550);
    $('crosshair').style.setProperty('--gap', `${(s.aiming ? 3 : 6) + spreadGap}px`);
    show('crosshair', s.health > 0 && !(s.aiming && s.slot === 2)); show('scope', s.aiming && s.slot === 2 && s.health > 0);
    $('hitmarker').style.opacity = s.hitmarker > 0 ? '1' : '0'; $('hitmarker').classList.toggle('headshot', s.headshot);
    $('damage-vignette').style.opacity = s.damage;
    show('interaction', planted && (s.bomb.near || s.bomb.defuser !== null) && s.phase === 'live');
    text('interaction-label', s.bomb.defuser === 9 ? 'DEFUSING — KEEP HOLDING E' : s.bomb.defuser !== null ? 'SQUADMATE IS DEFUSING' : 'HOLD E TO DEFUSE');
    const defuseTime = s.bomb.defuser === 9 ? 5 : 7;
    $('interaction-fill').style.width = `${s.bomb.defuse / defuseTime * 100}%`;
    text('interaction-detail', s.bomb.defuser !== null ? `${Math.max(0, defuseTime - s.bomb.defuse).toFixed(1)} SECONDS REMAINING` : 'YOUR DEFUSE KIT TAKES 5 SECONDS');
    show('spectator', s.health <= 0 && s.phase === 'live'); text('spectator-name', s.spectating);
    show('round-end', s.phase === 'end');
    text('winner-label', s.winner === 'CT' ? 'COUNTER-TERRORISTS WIN' : 'TERRORISTS WIN'); text('winner-title', s.winner === 'CT' ? 'SITE SECURED.' : 'DEFENSE BREACHED.'); text('winner-reason', s.reason); text('next-round', `NEXT ROUND IN ${Math.ceil(s.phaseTime)}`);
    if (s.phase === 'finished') {
      screenshotView(false);
      show('match-end', true); show('pause', false); show('buy-menu', false); show('scoreboard', false); ui.shop = false;
      clearInput(); showTouch();
      text('result-title', s.winner === 'CT' ? 'MISSION SECURED.' : 'MISSION LOST.'); text('result-ct', s.scores[0]); text('result-t', s.scores[1]);
      text('result-stats', `${s.kills} ELIMINATIONS · ${s.deaths} DEATHS · ${s.round} ROUNDS`);
      if (document.pointerLockElement) document.exitPointerLock();
    }
    if (ui.shop && (s.phase === 'end' || s.health <= 0)) capture();
    renderFeed(s); renderScores(s); drawMap($('radar'), s); renderAudio(s); previous = s;
  }
  function fail(error) {
    const panel = $('error'); panel.hidden = false; panel.replaceChildren();
    const title = document.createElement('strong'); title.textContent = 'Unable to start the 3D client.';
    const detail = document.createElement('p');
    const message = error?.message || String(error);
    detail.textContent = /import.*callable|LinkError|__wbg_/i.test(message)
      ? 'The browser loaded files from different game builds. Reload this page to fetch the current matched release. ' + message
      : /WebGL|GPU|adapter|context/i.test(message)
        ? message + '. Check that WebGL2 and hardware acceleration are enabled.'
        : message;
    const retry = document.createElement('button'); retry.className = 'primary'; retry.textContent = 'RETRY STARTUP'; retry.addEventListener('click', () => location.reload());
    const link = document.createElement('a'); link.href = './index.html'; link.textContent = 'Play the classic version →'; panel.append(title, detail, retry, link);
    if ($('loading')) $('loading').hidden = true;
    console.error(error);
  }
  canvas.addEventListener('webglcontextlost', event => { event.preventDefault(); pause(); fail(new Error('Graphics context lost. Reload to reconnect')); });
  window.desertStrike = {
    input: () => {
      const t = touch?.read() || {};
      const value = { active: active(), shop: ui.shop, touch: touchMode, forward: t.forward || 0, strafe: t.strafe || 0, sensitivity: ui.sensitivity, quality: ui.quality, seed: ui.seed, commands: ui.commands.splice(0), held: {...held}, lookX: lookX + (t.lookX || 0), lookY: lookY + (t.lookY || 0), firePressed: firePressed || !!t.firePressed, reloadPressed };
      if (t.fire) value.held.fire = true;
      if (t.aim) value.held.aim = true;
      if (t.crouch) value.held.ControlLeft = true;
      if (t.defuse) value.held.KeyE = true;
      lookX = 0; lookY = 0; firePressed = false; reloadPressed = false;
      return value;
    },
    render, fail, getDiagnostics: diagnostics, getState: () => state ? structuredClone(state) : null,
  };
})();
