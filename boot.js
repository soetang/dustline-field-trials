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
  // Compile as bytes arrive. Avoid retaining all download chunks and making a
  // second complete copy, especially on memory-constrained phones.
  const total = wasm.headers.get('content-encoding') ? 0 : Number(wasm.headers.get('content-length'));
  let moduleResponse = wasm;
  if (wasm.body && typeof TransformStream === 'function') {
    let received = 0;
    const progress = new TransformStream({
      transform(chunk, controller) {
        received += chunk.length;
        status.textContent = total ? `Loading game · ${Math.min(100, Math.round(received / total * 100))}%` : `Loading game · ${(received / 1048576).toFixed(1)} MB`;
        controller.enqueue(chunk);
      },
      flush() { status.textContent = 'Preparing graphics and shaders…'; },
    });
    moduleResponse = new Response(wasm.body.pipeThrough(progress), {headers: wasm.headers});
  }
  // The generated loader falls back to ArrayBuffer for servers with unsuitable
  // MIME types or browsers without streaming compilation.
  await init({ module_or_path: moduleResponse });
} catch (error) {
  window.desertStrike.fail(error);
}
