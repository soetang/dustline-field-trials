'use strict';
// Staged architecture review in the release WebGL engine, NOT gameplay/FPS.
// The official template ignores --script. Export a separate, temporary review
// entry point instead; never add test commands or resources to the public pack.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { launchBrowser } = require('../../scripts/browser-options');

(async () => {
  const project = path.resolve(__dirname, '..');
  const candidate = fs.readFileSync(path.join(project, 'builds/web-candidate.txt'), 'utf8').trim();
  assert.match(candidate, /^courtyard-[\w-]+$/);
  const release = path.join(project, 'builds/web-releases', candidate);
  const artifacts = fs.mkdtempSync(path.resolve(project, '../artifacts/map-review-browser-'));
  const reviewProject = path.join(artifacts,'project');
  fs.mkdirSync(reviewProject);
  for (const name of ['project.godot','export_presets.cfg','main.tscn','scripts','assets','shaders','web','.godot'])
    fs.cpSync(path.join(project,name),path.join(reviewProject,name),{recursive:true,filter:file=>!file.includes('/shader_cache')});
  const settings = fs.readFileSync(path.join(project,'project.godot'),'utf8').replace('run/main_scene="res://main.tscn"','run/main_scene="res://_map_review.tscn"');
  fs.writeFileSync(path.join(reviewProject,'project.godot'),settings);
  const presets = fs.readFileSync(path.join(project,'export_presets.cfg'),'utf8').replaceAll('../.tools/',path.resolve(project,'../.tools')+'/');
  fs.writeFileSync(path.join(reviewProject,'export_presets.cfg'),presets);
  // Mechanical SceneTree-to-Node adapter: both runners execute the same poses
  // and capture code, but an exported game needs a normal main scene.
  const reviewScript = fs.readFileSync(path.join(__dirname,'map_review.gd'),'utf8')
    .replace('extends SceneTree','extends Node').replace('func _initialize()','func _ready()')
    .replaceAll('await process_frame','await get_tree().process_frame')
    .replaceAll('root.','get_tree().root.').replaceAll('current_scene = game','get_tree().current_scene = game')
    .replaceAll('quit(','get_tree().quit(');
  fs.writeFileSync(path.join(reviewProject,'_map_review.gd'),reviewScript);
  fs.writeFileSync(path.join(reviewProject,'_map_review.tscn'),'[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://_map_review.gd" id="1"]\n[node name="MapReview" type="Node"]\nscript = ExtResource("1")\n');
  const godot = process.env.GODOT_BIN || path.resolve(project,'../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64');
  const reviewPack = path.join(artifacts,'index.pck');
  for (const extra of [['--editor','--import'],['--export-pack','Web',reviewPack]]) {
    const result = spawnSync(godot,['--headless','--path',reviewProject,...extra],{encoding:'utf8',timeout:90000,maxBuffer:4*1024*1024});
    const output = (result.stdout || '')+(result.stderr || '');
    fs.writeFileSync(path.join(artifacts,extra[0]==='--editor'?'import.log':'export.log'),output);
    assert.equal(result.status,0,output || String(result.error));
    assert.doesNotMatch(output,/SCRIPT ERROR:|^ERROR:/m);
  }
  console.log('Review pack prepared:',artifacts);
  const args = ['--','--test'];
  if (process.argv.includes('--diagnostic-no-shadows')) args.push('--diagnostic-no-shadows');
  const html = `<!doctype html><html><body style="margin:0"><canvas id="canvas" width="960" height="540"></canvas>
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
  const watchdog = setTimeout(() => browser?.close(),180000);
  watchdog.unref();
  try {
    browser = await launchBrowser(chromium);
    const page = await browser.newPage({viewport:{width:960,height:540},deviceScaleFactor:1});
    page.on('console', message => {
      logs.push(`${message.type()}: ${message.text()}`);
      console.log(message.text());
      if (message.type() === 'error') failures.push(message.text());
    });
    page.on('pageerror', error => failures.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(() => window.mapReviewComplete === true, null, {timeout:150000});
    assert.equal(await page.evaluate(() => window.mapReviewExit),undefined,'Review stays alive until the page is closed');
    const captures = await page.evaluate(() => window.mapReviewCaptures);
    assert.deepEqual(captures.map(c => c.name),['house','spawn','a-exit','mid-doors','long-doors']);
    for (const capture of captures) {
      assert.match(capture.name,/^[a-z-]+$/);
      const png = Buffer.from(capture.png,'base64');
      assert.equal(png.readUInt32BE(0),0x89504e47);
      fs.writeFileSync(path.join(artifacts,capture.name+'.png'),png);
      delete capture.png;
    }
    fs.writeFileSync(path.join(artifacts,'captures.json'),JSON.stringify({candidate,staged:true,args,captures},null,2)+'\n');
    assert.deepEqual(failures,[]);
    assert.ok(logs.some(line => line.includes('MAP_REVIEW_OK')));
    console.log('PASS: five staged map views. Artifacts:',artifacts);
  } finally {
    clearTimeout(watchdog);
    fs.writeFileSync(path.join(artifacts,'console.log'),logs.join('\n')+'\n');
    await browser?.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode=1; });
