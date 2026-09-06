'use strict';
// Staged architecture review in the release WebGL engine, NOT gameplay/FPS.
// The official template ignores --script. Export a separate, temporary review
// entry point instead; never add test commands or resources to the public pack.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { launchBrowser } = require('../../scripts/browser-options');

(async () => {
  const project = path.resolve(__dirname, '..');
  const benchmark = process.argv.includes('--benchmark');
  const wallReview = process.argv.includes('--wall-review');
  assert.ok(!wallReview || !benchmark,'Choose wall review or benchmark, not both');
  const windowsRenderOnly = process.argv.includes('--windows-render-only');
  const steadyProfile = process.argv.includes('--profile-steady');
  assert.ok(!steadyProfile || (benchmark && !process.argv.includes('--profile')),
    'Use --profile-steady only with --benchmark and without --profile');
  assert.ok(!windowsRenderOnly || benchmark || wallReview,'Windows renderer is only allowed for no-input render fixtures');
  const candidate = fs.readFileSync(path.join(project, 'builds/web-candidate.txt'), 'utf8').trim();
  assert.match(candidate, /^courtyard-[\w-]+$/);
  let release = path.join(project, 'builds/web-releases', candidate);
  const engineTemplateArg=process.argv.find(arg=>arg.startsWith('--engine-template='))?.slice('--engine-template='.length);
  const engineTemplate=engineTemplateArg && path.resolve(engineTemplateArg);
  assert.ok(!engineTemplate || (benchmark && engineTemplate.endsWith('.zip') && fs.statSync(engineTemplate).isFile()),
    'Custom engine templates are allowed only in isolated benchmarks');
  const artifacts = fs.mkdtempSync(path.resolve(project, '../artifacts/map-review-browser-'));
  const reviewProject = path.join(artifacts,'project');
  fs.mkdirSync(reviewProject);
  for (const name of ['project.godot','export_presets.cfg','main.tscn','scripts','assets','shaders','web','.godot'])
    fs.cpSync(path.join(project,name),path.join(reviewProject,name),{recursive:true,filter:file=>!file.includes('/shader_cache')});
  const batchCell = process.argv.find(arg=>arg.startsWith('--batch-cell='))?.split('=')[1];
  if (batchCell) {
    assert.ok(benchmark && ['8','16','24'].includes(batchCell));
    const file=path.join(reviewProject,'scripts/world.gd');
    const source=fs.readFileSync(file,'utf8');
    assert.match(source,/const BATCH_CELL_SIZE := [\d.]+/);
    fs.writeFileSync(file,source.replace(/const BATCH_CELL_SIZE := [\d.]+/,`const BATCH_CELL_SIZE := ${batchCell}.0`));
  }
  const settings = fs.readFileSync(path.join(project,'project.godot'),'utf8').replace('run/main_scene="res://main.tscn"','run/main_scene="res://_map_review.tscn"');
  fs.writeFileSync(path.join(reviewProject,'project.godot'),settings);
  let presets = fs.readFileSync(path.join(project,'export_presets.cfg'),'utf8').replaceAll('../.tools/',path.resolve(project,'../.tools')+'/');
  if (engineTemplate) {
    assert.doesNotMatch(engineTemplate,/["\r\n\\]/);
    const templateSetting=/custom_template\/release="[^"\n]*\/web_nothreads_release\.zip"/;
    assert.match(presets,templateSetting);
    presets=presets.replace(templateSetting,()=>`custom_template/release="${engineTemplate}"`);
    release=path.join(artifacts,'runtime');
    fs.mkdirSync(release);
  }
  fs.writeFileSync(path.join(reviewProject,'export_presets.cfg'),presets);
  // Mechanical SceneTree-to-Node adapter: both runners execute the same poses
  // and capture code, but an exported game needs a normal main scene.
  const reviewScript = fs.readFileSync(path.join(__dirname,wallReview ? 'wall_review.gd' : benchmark ? 'render_benchmark.gd' : 'map_review.gd'),'utf8')
    .replace('extends SceneTree','extends Node').replace('func _initialize()','func _ready()')
    .replaceAll('await process_frame','await get_tree().process_frame')
    .replaceAll('await physics_frame','await get_tree().physics_frame')
    .replaceAll('root.','get_tree().root.').replaceAll('current_scene = game','get_tree().current_scene = game')
    .replaceAll('quit(','get_tree().quit(');
  fs.writeFileSync(path.join(reviewProject,'_map_review.gd'),reviewScript);
  fs.writeFileSync(path.join(reviewProject,'_map_review.tscn'),'[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://_map_review.gd" id="1"]\n[node name="MapReview" type="Node"]\nscript = ExtResource("1")\n');
  const godot = process.env.GODOT_BIN || path.resolve(project,'../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64');
  const reviewPack = path.join(engineTemplate ? release : artifacts,'index.pck');
  const exportArgs=engineTemplate ? ['--export-release','Web',path.join(release,'index.html')] : ['--export-pack','Web',reviewPack];
  for (const extra of [['--editor','--import'],exportArgs]) {
    const result = spawnSync(godot,['--headless','--path',reviewProject,...extra],{encoding:'utf8',timeout:90000,maxBuffer:4*1024*1024});
    const output = (result.stdout || '')+(result.stderr || '');
    fs.writeFileSync(path.join(artifacts,extra[0]==='--editor'?'import.log':'export.log'),output);
    assert.equal(result.status,0,output || String(result.error));
    assert.doesNotMatch(output,/SCRIPT ERROR:|^ERROR:/m);
  }
  console.log('Review pack prepared:',artifacts);
  const engine = {template:engineTemplate ? path.basename(engineTemplate) : 'official 4.7.2',
    wasm_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(release,'index.wasm'))).digest('hex'),
    js_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(release,'index.js'))).digest('hex')};
  const args = ['--','--test'];
  if (process.argv.includes('--diagnostic-no-shadows')) args.push('--diagnostic-no-shadows');
  if (process.argv.includes('--capture')) args.push('--capture');
  if (process.argv.includes('--compare')) args.push('--compare');
  if (process.argv.includes('--compare-ssao')) args.push('--compare-ssao');
  if (process.argv.includes('--no-color-batching')) args.push('--no-color-batching');
  if (process.argv.includes('--color-batching')) args.push('--color-batching');
  if (steadyProfile) args.push('--profile-steady');
  for (const arg of process.argv.slice(2))
    if (/^--(samples|warmup|width|height|splits|shadow-distance|quality)=\d+$/.test(arg)) args.push(arg);
  const dimension = (name,fallback) => Number(args.find(arg=>arg.startsWith(`--${name}=`))?.split('=')[1] || fallback);
  const width = benchmark ? dimension('width',640) : 960;
  const height = benchmark ? dimension('height',360) : wallReview ? 441 : 540;
  const html = `<!doctype html><html><body style="margin:0"><canvas id="canvas" width="${width}" height="${height}"></canvas>
    <script src="index.js"></script><script>
      window.mapReviewCaptures=[];
      const engine=new Engine({executable:'index',mainPack:'index.pck',canvas:document.getElementById('canvas'),
        canvasResizePolicy:0,args:${JSON.stringify(args)},
        onPrint:console.log,onPrintError:console.error,onExit:code=>window.mapReviewExit=code});
      engine.startGame().catch(console.error);
    </script></body></html>`;
  const server = http.createServer((req,res) => {
    if (req.url === '/') { res.writeHead(200, {'Content-Type':'text/html'}).end(html); return; }
    if (req.url === '/favicon.ico') { res.writeHead(204).end(); return; }
    const filename = req.url.slice(1);
    const file = filename === 'index.pck' ? reviewPack : path.join(release,filename);
    if (!/^[\w.-]+$/.test(filename) || !fs.existsSync(file)) { res.writeHead(404).end(); return; }
    const type = filename.endsWith('.wasm') ? 'application/wasm' : filename.endsWith('.js') ? 'application/javascript' : 'application/octet-stream';
    res.writeHead(200,{'Content-Type':type});
    fs.createReadStream(file).pipe(res);
  });
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  let browser;
  const logs = [], failures = [];
  const watchdog = setTimeout(() => browser?.close(),benchmark || wallReview ? 600000 : 180000);
  watchdog.unref();
  try {
    browser = windowsRenderOnly ? await require('../../scripts/windows-browser')(chromium,{highPerformanceGPU:process.argv.includes('--high-performance-gpu')}) : await launchBrowser(chromium);
    const page = await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
    if (windowsRenderOnly) {
      // Separate headless profile, render-only: no host-input opt-in, no UI
      // actions. Immutable denial installed before any engine code can run.
      await page.addInitScript(() => {
        for (const name of ['requestPointerLock','webkitRequestPointerLock','mozRequestPointerLock','requestFullscreen'])
          Object.defineProperty(Element.prototype,name,{value:()=>{throw new Error('Host input forbidden in render-only benchmark');},writable:false,configurable:false});
      });
      for (const device of [page.mouse,page.keyboard,page.touchscreen])
        for (const name of ['click','dblclick','move','down','up','press','type','insertText','tap'])
          if (typeof device[name] === 'function') device[name]=()=>{throw new Error('No input in render-only benchmark');};
    }
    page.on('console', message => {
      logs.push(`${message.type()}: ${message.text()}`);
      console.log(message.text());
      if (message.type() === 'error') failures.push(message.text());
    });
    page.on('pageerror', error => failures.push(error.message));
    let profiler;
    if (process.argv.includes('--profile')) {
      profiler=await page.context().newCDPSession(page);
      await profiler.send('Profiler.enable');
      await profiler.send('Profiler.start');
    }
    await page.goto(`http://127.0.0.1:${server.address().port}/`,{waitUntil:'domcontentloaded'});
    if (steadyProfile) {
      // Explicit handshake after each warmup and before each screenshot.
      // Do not attribute first-load shader compilation to steady rendering.
      profiler=await page.context().newCDPSession(page);
      await profiler.send('Profiler.enable');
      while (true) {
        await page.waitForFunction(() => window.renderProfilePhase === 'ready' || window.mapReviewComplete,
          null,{timeout:180000});
        if (await page.evaluate(() => window.mapReviewComplete)) break;
        const name=await page.evaluate(() => window.renderProfileName);
        assert.match(name,/^[a-z-]+$/);
        await profiler.send('Profiler.start');
        await page.evaluate(() => { window.renderProfilePhase='running'; });
        await page.waitForFunction(() => window.renderProfilePhase === 'done',null,{timeout:180000});
        const {profile}=await profiler.send('Profiler.stop');
        fs.writeFileSync(path.join(artifacts,`${name}.cpuprofile`),JSON.stringify(profile));
        await page.evaluate(() => { window.renderProfilePhase='stopped'; });
        console.log('Warmed render CPU profile saved:',name);
      }
      profiler=null;
    }
    await page.waitForFunction(() => window.mapReviewComplete === true, null, {timeout:benchmark || wallReview ? 570000 : 150000});
    if (profiler) {
      const {profile}=await profiler.send('Profiler.stop');
      fs.writeFileSync(path.join(artifacts,'render.cpuprofile'),JSON.stringify(profile));
      console.log('CPU sampling profile saved (includes startup, warmup and captures):',path.join(artifacts,'render.cpuprofile'));
    }
    assert.equal(await page.evaluate(() => window.mapReviewExit),undefined,'Review stays alive until the page is closed');
    const captures = await page.evaluate(() => window.mapReviewCaptures);
    const poses = ['spawn','a-site','long-doors'];
    const modes=process.argv.includes('--compare-ssao') ? ['ao-before','no-ao-before','no-ao-after','ao-after'] : ['high-before','balanced-before','balanced-after','high-after'];
    const expected = process.argv.includes('--compare') || process.argv.includes('--compare-ssao') ? poses.flatMap(name=>modes.map(mode=>`${name}-${mode}`)) : poses;
    const expectedWalls=['ct-clear',...['ct','t'].flatMap(team=>['zero','thirty','sixty','ninety'].map(angle=>`${team}-angle-${angle}`)),
      'door-near','door-far','player-reported'];
    assert.deepEqual(captures.map(c => c.name),wallReview ? expectedWalls : benchmark ? expected : ['house','spawn','a-exit','mid-doors','long-doors']);
    for (const capture of captures) {
      assert.match(capture.name,/^[a-z-]+$/);
      if (wallReview) {
        assert.equal(capture.weapon_clear,true,`${capture.name}: whole weapon clears static geometry`);
        assert.ok(Number.isFinite(capture.weapon_withdrawal));
        if (capture.name === 'ct-clear' || capture.name.endsWith('-ninety'))
          assert.equal(capture.weapon_withdrawal,0,`${capture.name}: unrestricted pose is preserved`);
        else assert.ok(capture.weapon_withdrawal > 0,`${capture.name}: wall-aware withdrawal is exercised`);
      }
      if (benchmark) {
        assert.ok(capture.samples_ms.length >= 12);
        if (!capture.png) continue;
      }
      const png = Buffer.from(capture.png,'base64');
      assert.equal(png.readUInt32BE(0),0x89504e47);
      fs.writeFileSync(path.join(artifacts,capture.name+'.png'),png);
      delete capture.png;
    }
    fs.writeFileSync(path.join(artifacts,'captures.json'),JSON.stringify({candidate,engine,staged:true,args,captures},null,2)+'\n');
    assert.deepEqual(failures,[]);
    assert.ok(logs.some(line => line.includes(wallReview ? 'WALL_REVIEW_OK' : benchmark ? 'RENDER_BENCHMARK_OK' : 'MAP_REVIEW_OK')));
    console.log('PASS:',wallReview ? 'twelve staged wall/weapon views.' : benchmark ? 'staged render benchmark (not gameplay/hardware FPS).' : 'five staged map views.', 'Artifacts:',artifacts);
  } finally {
    clearTimeout(watchdog);
    fs.writeFileSync(path.join(artifacts,'console.log'),logs.join('\n')+'\n');
    await browser?.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode=1; });
