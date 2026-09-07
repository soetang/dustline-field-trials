'use strict';
// Isolated architecture/render reviews and instrumented AI gameplay fixtures.
// Software rendering checks correctness, not hardware FPS.
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
  const engineLifecycle = process.argv.includes('--engine-lifecycle');
  const expectCachedBackbuffer = process.argv.includes('--expect-cached-backbuffer');
  const wallReview = process.argv.includes('--wall-review');
  const hudReview = process.argv.includes('--hud-review');
  const gameplayProfile = process.argv.includes('--gameplay-profile');
  const navigationAbba = process.argv.includes('--navigation-abba');
  const presentationAbba = process.argv.includes('--presentation-abba');
  const presentationCache = process.argv.includes('--presentation-cache');
  const gpuTiming = process.argv.includes('--gpu-timing');
  const ssaoUnroll = process.argv.includes('--ssao-unroll');
  const operatorSurface = process.argv.includes('--operator-surface');
  assert.ok(!hudReview || !process.argv.some(arg=>/^--(compare|quality=|diagnostic-no-shadows|batch-cell=|color-batching|no-color-batching|simple-crates|splits=|shadow-distance=|engine-template=|profile)/.test(arg)),
    'HUD review preserves the official engine and unchanged High graphics');
  assert.ok(!operatorSurface || ((benchmark || wallReview) && !presentationCache && !gpuTiming && !ssaoUnroll &&
    !process.argv.some(arg=>/^--(compare|quality=|diagnostic-no-shadows|batch-cell=|color-batching|no-color-batching|simple-crates|splits=|shadow-distance=|engine-template=)/.test(arg))),
    'Operator surface merge requires an isolated official-engine High render or wall fixture');
  assert.ok(!ssaoUnroll || (benchmark && !presentationCache && !gpuTiming &&
    !process.argv.some(arg=>/^--(compare|quality=|diagnostic-no-shadows|batch-cell=|color-batching|no-color-batching|simple-crates|splits=|shadow-distance=|engine-template=)/.test(arg))),
    'SSAO unroll requires the isolated official-engine render benchmark with unchanged High settings');
  const simpleCrates = process.argv.includes('--simple-crates');
  // --crate-detail remains a harmless alias for the now-standard visuals.
  assert.ok(!simpleCrates || (!wallReview && !gameplayProfile && !engineLifecycle && !process.argv.includes('--crate-detail')),
    'Simple-crate comparison is only available in map/render fixtures');
  assert.ok(!navigationAbba || gameplayProfile,'Navigation ABBA requires --gameplay-profile');
  assert.ok(!presentationAbba || (gameplayProfile && !navigationAbba),'Presentation ABBA requires --gameplay-profile without --navigation-abba');
  assert.ok(!presentationCache || ((benchmark || engineLifecycle) && !presentationAbba),'Fixed presentation cache is only available in render/engine fixtures');
  assert.ok(!gpuTiming || ((benchmark || gameplayProfile) && !presentationAbba && !navigationAbba),
    'GPU timing requires an isolated benchmark or gameplay profile without other experiments');
  assert.ok([benchmark,wallReview,hudReview,gameplayProfile,engineLifecycle].filter(Boolean).length <= 1,'Choose one review/profile mode');
  const longFixture = benchmark || wallReview || hudReview || gameplayProfile || engineLifecycle;
  const windowsRenderOnly = process.argv.includes('--windows-render-only');
  const steadyProfile = process.argv.includes('--profile-steady');
  assert.ok(!steadyProfile || ((benchmark || gameplayProfile) && !process.argv.includes('--profile')),
    'Use --profile-steady with --benchmark or --gameplay-profile and without --profile');
  assert.ok(!windowsRenderOnly || longFixture,'Windows renderer is only allowed for no-host-input fixtures');
  assert.ok(!gameplayProfile || !process.argv.some(arg=>/^--(compare|compare-ssao|quality=|diagnostic-no-shadows|batch-cell=|color-batching|no-color-batching)/.test(arg)),
    'Gameplay profile preserves default High graphics');
  const candidate = fs.readFileSync(path.join(project, 'builds/web-candidate.txt'), 'utf8').trim();
  assert.match(candidate, /^courtyard-[\w-]+$/);
  let release = path.join(project, 'builds/web-releases', candidate);
  const engineTemplateArg=process.argv.find(arg=>arg.startsWith('--engine-template='))?.slice('--engine-template='.length);
  const engineTemplate=engineTemplateArg && path.resolve(engineTemplateArg);
  assert.ok(!engineTemplate || ((benchmark || engineLifecycle) && engineTemplate.endsWith('.zip') && fs.statSync(engineTemplate).isFile()),
    'Custom engine templates are allowed only in isolated render/engine fixtures');
  assert.ok(!expectCachedBackbuffer || (engineLifecycle && engineTemplate),'Cached-backbuffer expectation requires a custom engine lifecycle fixture');
  const artifacts = fs.mkdtempSync(path.resolve(project, '../artifacts/map-review-browser-'));
  const reviewProject = path.join(artifacts,'project');
  fs.mkdirSync(reviewProject);
  for (const name of ['project.godot','export_presets.cfg','main.tscn','scripts','assets','shaders','web','.godot'])
    fs.cpSync(path.join(project,name),path.join(reviewProject,name),{recursive:true,filter:file=>!file.includes('/shader_cache')});
  if (hudReview) fs.copyFileSync(path.join(project,'engine/experiments/hud_retained.gd'),path.join(reviewProject,'_hud_retained.gd'));
  if (operatorSurface) {
    fs.copyFileSync(path.join(project,'engine/experiments/operator_surface.gdshader'),path.join(reviewProject,'_operator_surface.gdshader'));
    const source=fs.readFileSync(path.join(project,'engine/experiments/operator_surface.gd'),'utf8');
    const shaderPath='res://engine/experiments/operator_surface.gdshader';
    assert.equal(source.split(shaderPath).length,2);
    fs.writeFileSync(path.join(reviewProject,'_operator_surface.gd'),source.replace(shaderPath,'res://_operator_surface.gdshader'));
    const file=path.join(reviewProject,'scripts/bot.gd');
    const bot=fs.readFileSync(file,'utf8'),anchor='\tModels.prepare(model)\n';
    assert.equal(bot.split(anchor).length,2,'One original operator preparation point');
    fs.writeFileSync(file,bot.replace(anchor,anchor+
      '\tif not preload("res://_operator_surface.gd").apply(model):\n'+
      '\t\tpush_error("OPERATOR_SURFACE_REJECTED " + preload("res://_operator_surface.gd").last_error)\n'+
      '\telse: print("OPERATOR_SURFACE_READY ", index)\n'));
  }
  let instrumentation;
  if (gameplayProfile) {
    fs.copyFileSync(path.join(__dirname,'cpu_profile.gd'),path.join(reviewProject,'_cpu_profile.gd'));
    instrumentation=require('./profile_instrumentation').instrumentProject(reviewProject);
    fs.writeFileSync(path.join(artifacts,'instrumentation.json'),JSON.stringify(instrumentation,null,2)+'\n');
    // No synthetic mouse capture, even during an automatic BUY -> LIVE
    // transition. Immutable DOM/input denial below remains the second guard.
    const file=path.join(reviewProject,'scripts/game.gd');
    const source=fs.readFileSync(file,'utf8');
    assert.equal((source.match(/Input\.mouse_mode = Input\.MOUSE_MODE_CAPTURED/g)||[]).length,2);
    fs.writeFileSync(file,source.replaceAll('Input.mouse_mode = Input.MOUSE_MODE_CAPTURED','Input.mouse_mode = Input.MOUSE_MODE_VISIBLE'));
    if (navigationAbba) {
      const layoutFile=path.join(reviewProject,'scripts/layout.gd');
      const layoutSource=fs.readFileSync(layoutFile,'utf8');
      const predicate='if not clear(from.lerp(to, float(i) / count), NAV_RADIUS):';
      assert.equal(layoutSource.split(predicate).length,2,'Exactly one segment predicate must be adapted');
      fs.writeFileSync(layoutFile,layoutSource.replace(predicate,
        'if not (_clear_direct(from.lerp(to, float(i) / count), NAV_RADIUS) if CpuProbe.reference_navigation else clear(from.lerp(to, float(i) / count), NAV_RADIUS)):'));
    }
  }
  const batchCell = process.argv.find(arg=>arg.startsWith('--batch-cell='))?.split('=')[1];
  if (simpleCrates) {
    const file=path.join(reviewProject,'scripts/world.gd');
    const source=fs.readFileSync(file,'utf8');
    const start=source.indexOf('func crate(rect: Rect2, index: int) -> void:');
    const end=source.indexOf('\nfunc arch(',start);
    assert.ok(start>=0 && end>start,'Comparison replaces only the crate visual constructor');
    const replacement=`func crate(rect: Rect2, index: int) -> void:
\tvar center := rect.get_center()
\tvar height := 1.1 if index % 3 == 0 else 2.0
\tvar base := Layout.floor_height(center)
\tvar timber := material(Color("806e50") if index % 2 == 0 else Color("6d745d"))
\tvar band := material(Color("464d45"), 0.35)
\tbox(Vector3(center.x, base + height * 0.5, center.y), Vector3(rect.size.x, height, rect.size.y), timber, true)
\tfor side in [-1, 1]:
\t\tfor offset in [-0.32, 0.32]:
\t\t\tbox(Vector3(center.x + rect.size.x * offset, base + height * 0.5, center.y + side * (rect.size.y * 0.5 + 0.018)), Vector3(0.09, height + 0.02, 0.04), band)
\t\t\tbox(Vector3(center.x + side * (rect.size.x * 0.5 + 0.018), base + height * 0.5, center.y + rect.size.y * offset), Vector3(0.04, height + 0.02, 0.09), band)
`;
    fs.writeFileSync(file,source.slice(0,start)+replacement+source.slice(end));
  }
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
  if (gpuTiming) fs.copyFileSync(path.join(__dirname,'gpu_profile.gd'),path.join(reviewProject,'_gpu_profile.gd'));
  // Mechanical SceneTree-to-Node adapter: both runners execute the same poses
  // and capture code, but an exported game needs a normal main scene.
  let reviewScript = fs.readFileSync(path.join(__dirname,engineLifecycle ? 'engine_lifecycle.gd' : gameplayProfile ? 'gameplay_profile.gd' : hudReview ? 'hud_review.gd' : wallReview ? 'wall_review.gd' : benchmark ? 'render_benchmark.gd' : 'map_review.gd'),'utf8')
    .replace('extends SceneTree','extends Node').replace('func _initialize()','func _ready()')
    .replaceAll('await process_frame','await get_tree().process_frame')
    .replaceAll('await physics_frame','await get_tree().physics_frame')
    .replaceAll('gpu_probe.collect(self)','gpu_probe.collect(get_tree())')
    .replaceAll('root.','get_tree().root.').replaceAll('current_scene = game','get_tree().current_scene = game')
    .replaceAll('quit(','get_tree().quit(');
  if (hudReview) reviewScript=reviewScript.replace('res://engine/experiments/hud_retained.gd','res://_hud_retained.gd');
  if (gameplayProfile) reviewScript=reviewScript
    .replace('res://tests/cpu_profile.gd','res://_cpu_profile.gd')
    .replace('const LABELS: Array[String] = []',`const LABELS: Array[String] = ${JSON.stringify(instrumentation.labels)}`);
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
  if (navigationAbba) args.push('--navigation-abba');
  if (presentationAbba) args.push('--presentation-abba');
  if (gpuTiming) args.push('--gpu-timing');
  if (expectCachedBackbuffer) args.push('--expect-cached-backbuffer');
  for (const arg of process.argv.slice(2))
    if (/^--(samples|warmup|width|height|splits|shadow-distance|quality|duration)=\d+$/.test(arg)) args.push(arg);
  const dimension = (name,fallback) => Number(args.find(arg=>arg.startsWith(`--${name}=`))?.split('=')[1] || fallback);
  const width = benchmark || gameplayProfile || engineLifecycle ? dimension('width',gameplayProfile ? 1280 : 640) : 960;
  const height = benchmark || gameplayProfile || engineLifecycle ? dimension('height',gameplayProfile ? 720 : 360) : wallReview ? 441 : 540;
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
  const watchdog = setTimeout(() => browser?.close(),longFixture ? 600000 : 180000);
  watchdog.unref();
  try {
    browser = windowsRenderOnly ? await require('../../scripts/windows-browser')(chromium,{highPerformanceGPU:process.argv.includes('--high-performance-gpu')}) : await launchBrowser(chromium);
    const page = await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
    if (ssaoUnroll) {
      const source=fs.readFileSync(path.join(project,'engine/experiments/ssao-unroll.js'),'utf8');
      await page.addInitScript({content:source+
        '\nwindow.ssaoUnroll=window.SsaoUnroll.installCanvasHook(HTMLCanvasElement.prototype,{enabled:true});'});
    }
    if (presentationAbba || presentationCache) {
      const source=fs.readFileSync(path.join(project,'engine/experiments/presentation-state-cache.js'),'utf8');
      await page.addInitScript({content:source+(presentationCache ? '\nwindow.presentationStateCache.setEnabled(true);' : '')});
    }
    if (gpuTiming) await page.addInitScript({path:path.join(project,'engine/experiments/gpu-timer-probe.js')});
    if (engineLifecycle) await page.addInitScript({path:path.join(project,'engine/experiments/backbuffer-gl-audit.js')});
    if (hudReview) await page.addInitScript({path:path.join(__dirname,'hud-buffer-probe.js')});
    if (windowsRenderOnly || hudReview) {
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
    page.on('pageerror', error => {
      failures.push(error.message);
      logs.push(`pageerror: ${error.message}`);
      console.error('Page error:',error.message);
    });
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
        console.log('Warmed CPU profile saved:',name);
      }
      profiler=null;
    }
    await page.waitForFunction(() => window.mapReviewComplete === true, null, {timeout:longFixture ? 570000 : 150000});
    if (profiler) {
      const {profile}=await profiler.send('Profiler.stop');
      fs.writeFileSync(path.join(artifacts,'render.cpuprofile'),JSON.stringify(profile));
      console.log('CPU sampling profile saved (includes startup, warmup and captures):',path.join(artifacts,'render.cpuprofile'));
    }
    assert.equal(await page.evaluate(() => window.mapReviewExit),undefined,'Review stays alive until the page is closed');
    const captures = await page.evaluate(() => window.mapReviewCaptures);
    if (operatorSurface) assert.equal(logs.filter(line=>line.includes('OPERATOR_SURFACE_READY ')).length,9,
      'All nine real operator models use the merged fixture, without silent fallback');
    const poses = ['spawn','a-site','long-doors'];
    const modes=process.argv.includes('--compare-ssao') ? ['ao-before','no-ao-before','no-ao-after','ao-after'] : ['high-before','balanced-before','balanced-after','high-after'];
    const expected = process.argv.includes('--compare') || process.argv.includes('--compare-ssao') ? poses.flatMap(name=>modes.map(mode=>`${name}-${mode}`)) : poses;
    const expectedWalls=['ct-clear',...['ct','t'].flatMap(team=>['zero','thirty','sixty','ninety'].map(angle=>`${team}-angle-${angle}`)),
      'door-near','door-far','player-reported'];
    const expectedGameplay = gpuTiming ? ['timer-off-before','timer-on-before','timer-on-after','timer-off-after']
      : presentationAbba ? ['native-before','cache-before','cache-after','native-after']
      : navigationAbba ? ['reference-before','lookup-before','lookup-after','reference-after']
      : ['control-before','profile-before','profile-after','control-after'];
    const expectedHud=['buy','live','damage','spectator','scoreboard','pause','resized'].flatMap(name=>[`${name}-reference`,`${name}-retained`]);
    assert.deepEqual(captures.map(c => c.name),engineLifecycle ? ['depth-only','depth-and-color','resized','msaa-2x','msaa-4x','restored'] : gameplayProfile ? expectedGameplay : hudReview ? expectedHud : wallReview ? expectedWalls : benchmark ? expected : ['house','spawn','a-exit','mid-doors','long-doors']);
    if (hudReview) {
      const {PNG}=require('playwright-core/lib/utilsBundle.js');
      // Preserve all evidence even when the candidate's first comparison fails.
      for (const capture of captures) fs.writeFileSync(path.join(artifacts,capture.name+'.png'),Buffer.from(capture.png,'base64'));
      fs.writeFileSync(path.join(artifacts,'hud-comparison.json'),JSON.stringify(captures.map(({png,...data})=>data),null,2)+'\n');
      for (let i=0;i<captures.length;i+=2) {
        const reference=captures[i],retained=captures[i+1];
        for (const field of ['quality','ssao','scale_3d','viewport','viewport_pixels','logical_size','render_3d'])
          assert.deepEqual(retained.render[field],reference.render[field],`Same ${field}`);
        assert.equal(retained.render.quality,'High');
        assert.equal(retained.render.scale_3d,1);
        assert.equal(retained.render.ssao,true);
        assert.equal(reference.frames,24);
        assert.equal(retained.frames,24);
        const a=PNG.sync.read(Buffer.from(reference.png,'base64')),b=PNG.sync.read(Buffer.from(retained.png,'base64'));
        assert.deepEqual([a.width,a.height],[b.width,b.height]);
        let changed=0,maximum=0;
        for (let offset=0;offset<a.data.length;offset++) {
          const delta=Math.abs(a.data[offset]-b.data[offset]);
          if (delta) changed++;
          maximum=Math.max(maximum,delta);
        }
        assert.equal(changed,0,`${retained.name}: pixel-exact HUD compositing (${changed} channels differ, maximum ${maximum})`);
        for (const operation of ['createBuffer','deleteBuffer','bufferData'])
          assert.ok(reference.buffers[operation]-retained.buffers[operation]>=12*reference.frames,
            `${retained.name}: eliminates at least twelve static buffer ${operation} calls per frame`);
        for (const operation of ['createVertexArray','deleteVertexArray'])
          assert.ok(reference.buffers[operation]-retained.buffers[operation]>=6*reference.frames,
            `${retained.name}: eliminates at least six static VAO ${operation} calls per frame`);
      }
    }
    if (engineLifecycle) {
      const summary=await page.evaluate(() => window.engineLifecycleSummary);
      assert.equal(summary.stages,6);
      assert.equal(summary.failures,0,'All real framebuffer lifecycle assertions pass');
      assert.ok(summary.checks>0);
    }
    if (gameplayProfile) for (const capture of captures) assert.deepEqual(capture.camera,captures[0].camera,'All windows use an identical observer camera');
    for (const capture of captures) {
      assert.match(capture.name,/^[a-z0-9-]+$/);
      if (engineLifecycle) {
        assert.equal(capture.failures,0,`${capture.name}: engine lifecycle checks`);
        assert.equal(capture.expect_cached_backbuffer,expectCachedBackbuffer);
        assert.equal(capture.steady_frames,12);
        assert.equal(capture.steady_audit.contexts,1);
        if (!capture.png) continue;
      }
      if (gpuTiming) {
        const gpu=capture.gpu_timing;
        assert.ok(gpu && typeof gpu.supported === 'boolean','GPU probe reports availability and sample state');
        assert.equal(capture.gpu_timing_requested,benchmark || capture.name.startsWith('timer-on-'));
        assert.equal(gpu.enabled,false,'Sampling stops before summaries and captures');
        assert.equal(gpu.active,false,'No query straddles segment boundaries');
        assert.equal(gpu.stats.errors,0,gpu.last_error || 'No probe exceptions');
        assert.equal(gpu.allocated_queries <= gpu.config.poolSize,true,'Query storage stays bounded');
        assert.equal(gpu.valid_samples,gpu.samples.length);
        if (!gpu.supported || !capture.gpu_timing_requested) {
          assert.equal(gpu.valid_samples,0,'Disabled/unsupported queries cannot report measured GPU work');
          assert.equal(gpu.mean_ms,null,'Missing measurements are not zero milliseconds');
        }
        if (gpu.valid_samples) {
          assert.ok(Number.isFinite(gpu.mean_ms) && gpu.mean_ms >= 0);
          for (const sample of gpu.samples) {
            assert.equal(sample.segment_id,capture.name,'No samples leak between segments');
            assert.ok(Number.isFinite(sample.elapsed_ms) && sample.elapsed_ms >= 0);
          }
        }
        assert.equal(gpu.stats.blitCalls,gpu.stats.blitsInQuery+gpu.stats.blitsOutsideQuery);
      }
      if (wallReview) {
        assert.equal(capture.weapon_clear,true,`${capture.name}: whole weapon clears static geometry`);
        assert.ok(Number.isFinite(capture.weapon_withdrawal));
        if (capture.name === 'ct-clear' || capture.name.endsWith('-ninety'))
          assert.equal(capture.weapon_withdrawal,0,`${capture.name}: unrestricted pose is preserved`);
        else assert.ok(capture.weapon_withdrawal > 0,`${capture.name}: wall-aware withdrawal is exercised`);
      }
      if (gameplayProfile) {
        assert.equal(capture.dropped_frames,0,'Profile window did not overflow');
        assert.equal(capture.frames,capture.samples_ms.length);
        assert.equal(capture.camera.mismatched_frames,0,'Observer was current for every measured frame');
        assert.equal(capture.render.quality,'High');
        assert.equal(capture.render.scale_3d,1);
        assert.equal(capture.render.ssao,true);
        assert.ok(capture.physics_ticks > 0 && capture.bot_travel_m > 0,'Real AI and physics ran');
        assert.deepEqual(capture.scopes.map(row=>row.scope),instrumentation.labels);
        assert.equal(capture.instrumented,navigationAbba || capture.name.startsWith('profile-'));
        if (navigationAbba) assert.equal(capture.navigation,capture.name.startsWith('reference-') ? 'original exact predicate' : 'production clearance');
        if (presentationAbba) {
          assert.equal(capture.presentation_cache.length,1,'One owned WebGL2 canvas context');
          const state=capture.presentation_cache[0];
          assert.equal(state.enabled,capture.name.startsWith('cache-'));
          assert.equal(state.validation.lost,false,'No graphics context loss');
          assert.equal(state.validation.scissor,true,'Cached scissor agrees with native query');
          assert.equal(state.validation.draw,true,'Cached drawing framebuffer agrees with native query');
          assert.ok(state.enabled ? state.hits > 0 : state.hits === 0,'Selected presentation route exercised');
        }
        assert.ok(capture.instrumented ? capture.instrumented_self_ms > 0 : capture.instrumented_self_ms === 0);
        for (const row of capture.scopes) {
          assert.ok(row.inclusive_ms >= row.self_ms && row.self_ms >= 0);
          if (capture.instrumented && ['bot._physics_process','layout.segment_clear','operator_rig.update_pose','hud._draw'].includes(row.scope))
            assert.ok(row.calls > 0,`${row.scope}: core scope exercised`);
        }
      }
      if (benchmark || gameplayProfile) {
        assert.ok(capture.samples_ms.length >= 12);
        if (!capture.png) continue;
      }
      const png = Buffer.from(capture.png,'base64');
      assert.equal(png.readUInt32BE(0),0x89504e47);
      if (benchmark) assert.deepEqual([png.readUInt32BE(16),png.readUInt32BE(20)],capture.render.viewport_pixels,
        'Readback verifies actual viewport pixels, excluding window letterboxing');
      if (engineLifecycle) assert.deepEqual([png.readUInt32BE(16),png.readUInt32BE(20)],capture.resolution,
        'Readback dimensions reflect actual viewport resize');
      fs.writeFileSync(path.join(artifacts,capture.name+'.png'),png);
      delete capture.png;
    }
    const presentationState = presentationCache ? await page.evaluate(() => window.presentationStateCache.snapshot()) : null;
    if (presentationCache) {
      assert.equal(presentationState.length,1);
      const state=presentationState[0];
      assert.equal(state.enabled,true);
      assert.ok(state.hits > 0,'Cached presentation state was used');
      assert.deepEqual(state.validation,{lost:false,scissor:true,draw:true},'Cached state still matches native state');
    }
    // Compilation transforms only; take counters after all timed windows.
    const ssaoState = ssaoUnroll ? await page.evaluate(() => window.ssaoUnroll.snapshot()) : null;
    if (ssaoUnroll) {
      assert.equal(ssaoState.contexts,1);
      assert.equal(ssaoState.enabled,true);
      assert.ok(ssaoState.replaced > 0,'Actual engine shader source matched the pinned unroll');
      assert.equal(ssaoState.rejected,0,'No ambiguous Medium shader candidates');
      assert.equal(ssaoState.exceptions,0);
      assert.equal(ssaoState.adds_driver_queries,false);
      for (const capture of captures) {
        assert.equal(capture.render.quality,'High');
        assert.equal(capture.render.ssao,true);
        assert.equal(capture.render.scale_3d,1);
        assert.deepEqual(capture.render.viewport,[width,height]);
        assert.deepEqual(capture.render.render_3d,capture.render.viewport_pixels,'High does not downscale the actual viewport');
      }
    }
    fs.writeFileSync(path.join(artifacts,'captures.json'),JSON.stringify({candidate,engine,presentation_cache:presentationState,ssao_unroll:ssaoState,
      operator_surface:operatorSurface,
      crate_visuals:engineLifecycle ? null : simpleCrates ? '0.4.5 simple boxes and bands' : '0.4.6 detailed single-surface crates',staged:true,args,captures},null,2)+'\n');
    assert.deepEqual(failures,[]);
    assert.ok(logs.some(line => line.includes(engineLifecycle ? 'ENGINE_LIFECYCLE_OK' : gameplayProfile ? 'GAMEPLAY_PROFILE_OK' : hudReview ? 'HUD_REVIEW_OK' : wallReview ? 'WALL_REVIEW_OK' : benchmark ? 'RENDER_BENCHMARK_OK' : 'MAP_REVIEW_OK')));
    console.log('PASS:',engineLifecycle ? 'six isolated native WebGL framebuffer lifecycle stages.' : gameplayProfile ? 'test-only CPU scopes during an automated AI round (not human play).' : hudReview ? 'seven pixel-exact HUD comparisons with measured WebGL allocation reduction.' : wallReview ? 'twelve staged wall/weapon views.' : benchmark ? 'staged render benchmark (not gameplay/hardware FPS).' : 'five staged map views.', 'Artifacts:',artifacts);
  } finally {
    clearTimeout(watchdog);
    fs.writeFileSync(path.join(artifacts,'console.log'),logs.join('\n')+'\n');
    await browser?.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode=1; });
