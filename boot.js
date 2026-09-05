// Keep module loading inside the error boundary, including missing/stale releases.
const status = document.getElementById('load-status');
try {
  if (location.protocol === 'file:') throw new Error('Open http://localhost:8765/bevy.html after running npm run serve');
  const response = await fetch('./web/current.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`The game release is missing (HTTP ${response.status}). Run npm run build`);
  const release = await response.json();
  if (!/^\.\/web\/builds\/release-[\w-]+\/desert_strike\.js$/.test(release.entry)) throw new Error('Invalid game release manifest');
  window.desertStrike.release = release.entry;
  status.textContent = 'Loading the 3D engine…';
  const { default: init } = await import(release.entry);
  const wasm = await fetch(new URL('desert_strike_bg.wasm', new URL(release.entry, location.href)));
  if (!wasm.ok) throw new Error(`The game download failed (HTTP ${wasm.status}). Reload to retry`);
  const total = Number(wasm.headers.get('content-length'));
  let bytes;
  if (wasm.body && total) {
    const reader = wasm.body.getReader(), chunks = [];
    let received = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value); received += value.length;
      status.textContent = `Loading game · ${Math.min(100, Math.round(received / total * 100))}%`;
    }
    bytes = new Uint8Array(received); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  } else bytes = new Uint8Array(await wasm.arrayBuffer());
  status.textContent = 'Preparing graphics and shaders…';
  await init({ module_or_path: bytes });
} catch (error) {
  window.desertStrike.fail(error);
}
