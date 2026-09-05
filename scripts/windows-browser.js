'use strict';
// Optional WSL test runner: an isolated Windows Chrome profile, with CDP kept
// on loopback at both ends. No user browser/profile or firewall settings touched.
const fs=require('node:fs'),path=require('node:path'),net=require('node:net');
const {execFileSync,spawn}=require('node:child_process');
const powershell='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';
const quote=s=>`'${s.replaceAll("'","''")}'`;
const ps=script=>execFileSync(powershell,['-NoProfile','-NonInteractive','-Command',script],{encoding:'utf8',timeout:15000}).trim();
module.exports=async chromium=>{
  const locations=JSON.parse(ps('[pscustomobject]@{temp=$env:TEMP;chrome="${env:ProgramFiles}\\Google\\Chrome\\Application\\chrome.exe"}|ConvertTo-Json -Compress'));
  const localTemp=execFileSync('wslpath',['-u',locations.temp],{encoding:'utf8'}).trim();
  const profile=fs.mkdtempSync(path.join(localTemp,'dustline-browser-'));
  const windowsProfile=execFileSync('wslpath',['-w',profile],{encoding:'utf8'}).trim();
  // Match Playwright's foreground-test behavior for an otherwise headless,
  // native browser; Chrome must not throttle this window as an occluded app.
  const pid=Number(ps(`(Start-Process -FilePath ${quote(locations.chrome)} -ArgumentList @('--headless=new','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-background-timer-throttling','--disable-backgrounding-occluded-windows','--disable-renderer-backgrounding','--disable-extensions','--disable-component-update','--remote-debugging-port=0',${quote(`--user-data-dir="${windowsProfile}"`)},'about:blank') -PassThru).Id`));
  if(!Number.isInteger(pid)||pid<=0)throw new Error('Windows Chrome did not return a process ID');
  let browser,relay;const bridges=new Set(),sockets=new Set();let closed=false;
  const cleanup=async()=>{
    if(closed)return;closed=true;
    for(const socket of sockets)socket.destroy();
    for(const p of bridges)p.kill();
    if(relay)await new Promise(resolve=>relay.close(resolve));
    // Exact PID returned by our own launch, plus exact fresh profile check.
    try{ps(`$p=Get-CimInstance Win32_Process -Filter 'ProcessId = ${pid}';if($p -and $p.CommandLine.Contains(${quote(windowsProfile)})){Stop-Process -Id ${pid} -ErrorAction SilentlyContinue}`);}catch{}
  };
  try {
    const activePort=path.join(profile,'DevToolsActivePort');
    const deadline=Date.now()+15000;
    while(!fs.existsSync(activePort)&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,100));
    const [portText,endpoint]=fs.readFileSync(activePort,'utf8').trim().split(/\r?\n/);
    const port=Number(portText);
    if(!Number.isInteger(port)||port<1||port>65535||!endpoint.startsWith('/devtools/browser/'))throw new Error('Invalid Chrome debug endpoint');
    relay=net.createServer(socket=>{
      sockets.add(socket);
      const command=`$c=New-Object Net.Sockets.TcpClient('127.0.0.1',${port});$s=$c.GetStream();$a=[Console]::OpenStandardInput().CopyToAsync($s);$b=$s.CopyToAsync([Console]::OpenStandardOutput());[Threading.Tasks.Task]::WaitAny(@($a,$b)) > $null;$c.Close()`;
      const bridge=spawn(powershell,['-NoProfile','-NonInteractive','-Command',command],{stdio:['pipe','pipe','ignore']});
      bridges.add(bridge);socket.pipe(bridge.stdin);bridge.stdout.pipe(socket);
      socket.on('error',()=>{});bridge.stdin.on('error',()=>{});
      socket.on('close',()=>{sockets.delete(socket);bridge.kill();});
      bridge.on('error',()=>socket.destroy());
      bridge.on('exit',()=>{bridges.delete(bridge);socket.destroy();});
    });
    await new Promise((resolve,reject)=>{relay.once('error',reject);relay.listen(0,'127.0.0.1',resolve);});
    browser=await chromium.connectOverCDP(`ws://127.0.0.1:${relay.address().port}${endpoint}`,{timeout:20000});
    const disconnect=browser.close.bind(browser);
    browser.close=async()=>{
      if(closed)return;
      try{const cdp=await browser.newBrowserCDPSession();await cdp.send('Browser.close');}catch{}
      try{await disconnect();}finally{await cleanup();}
    };
    return browser;
  }catch(error){await cleanup();throw error;}
};
