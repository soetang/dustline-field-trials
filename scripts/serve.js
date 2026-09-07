'use strict';
// Loopback-only app server; never serves the repository, tools or compiler cache.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const mime = {'.html':'text/html; charset=utf-8','.js':'application/javascript','.css':'text/css',
  '.wasm':'application/wasm','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.glb':'model/gltf-binary'};

function createServer(root = path.resolve(__dirname, '..')) {
  return http.createServer(async (req, res) => {
    try {
      if (!['GET','HEAD'].includes(req.method)) { res.writeHead(405).end(); return; }
      const name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      const redirect = location => res.writeHead(302, {Location:location,'Cache-Control':'no-store'}).end();
      if (name === '/') return redirect('/courtyard/');
      if (['/bevy','/classic','/courtyard'].includes(name)) return redirect(name+'/');
      if (name === '/courtyard/') {
        const release = (await fs.promises.readFile(path.join(root,'courtyard/builds/web-candidate.txt'),'utf8')).trim();
        if (!/^courtyard-[\w-]+$/.test(release)) throw new Error('Invalid candidate');
        return redirect(`/courtyard/${release}/`);
      }
      let directory, relative;
      const courtyard = name.match(/^\/courtyard\/(courtyard-[\w-]+)\/(.*)$/);
      const bevyResource = name.match(/^\/bevy\/(web|assets|licenses)\/(.*)$/);
      if (courtyard) {
        directory = path.join(root,'courtyard/builds/web-releases',courtyard[1]);
        relative = courtyard[2] || 'index.html';
      } else if (bevyResource) {
        directory = path.join(root,'bevy',bevyResource[1]); relative = bevyResource[2];
      } else if (/^\/bevy\/(?:$|bevy\.(?:html|css)$|(?:boot|client|touch-controls)\.js$)/.test(name)) {
        directory = path.join(root,'bevy'); relative = name.slice(6) || 'bevy.html';
      } else if (/^\/classic\/(?:$|index\.html$|styles\.css$|game\.js$)/.test(name)) {
        directory = path.join(root,'classic'); relative = name.slice(9) || 'index.html';
      } else { res.writeHead(404).end(); return; }
      const file = path.resolve(directory,relative);
      if (!file.startsWith(directory+path.sep)) { res.writeHead(403).end(); return; }
      const real = await fs.promises.realpath(file);
      if (!real.startsWith((await fs.promises.realpath(directory))+path.sep)) { res.writeHead(403).end(); return; }
      if (!(await fs.promises.stat(real)).isFile()) { res.writeHead(404).end(); return; }
      let data = await fs.promises.readFile(real);
      // Production's ../../ fallback targets Bevy at the public site root.
      // Locally the root promotes Courtyard, so keep the fallback explicit.
      if (courtyard && relative === 'index.html')
        data = Buffer.from(data.toString().replaceAll('href="../../"','href="/bevy/bevy.html"'));
      res.writeHead(200, {'Content-Type':mime[path.extname(file)] || 'application/octet-stream',
        'Content-Length':data.length,'Cache-Control':'no-cache'});
      res.end(req.method === 'HEAD' ? undefined : data);
    } catch (error) {
      res.writeHead(error instanceof URIError ? 400 : 404, {'Content-Type':'text/plain'});
      res.end('App file unavailable. Build Courtyard with npm run build, or Bevy with npm run build:bevy.');
    }
  });
}

if (require.main === module) {
  const server = createServer();
  server.on('error', error => { console.error(error.message); process.exitCode = 1; });
  server.listen(8765,'127.0.0.1',()=>console.log('Newest: http://localhost:8765/ | Earlier: /bevy/bevy.html | Prototype: /classic/'));
}
module.exports = {createServer};
