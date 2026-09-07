(() => {
  'use strict';
  window.createDustlineTouchControls = ({enabled, active, pause, shop, reload, spectate}) => {
    const $ = id => document.getElementById(id);
    let forward=0,strafe=0,lookX=0,lookY=0,fire=false,firePressed=false,aim=false,crouch=false,defuse=false;
    const pointers=new Map();
    const knob=$('touch-knob'), stick=$('touch-move');
    const usable=e=>enabled && e.pointerType!=='mouse' && active();
    function reset() {
      const previous=[...pointers.entries()];pointers.clear();
      for(const [id,p] of previous) if(p.el.hasPointerCapture?.(id))p.el.releasePointerCapture(id);
      forward=strafe=lookX=lookY=0;fire=firePressed=aim=crouch=defuse=false;
      knob.style.transform='translate(0px,0px)';
      $('touch-aim').setAttribute('aria-pressed','false');
      $('touch-crouch').setAttribute('aria-pressed','false');
    }
    function begin(e,kind,el) {
      if(!usable(e) || [...pointers.values()].some(p=>p.kind===kind))return false;
      e.preventDefault();
      pointers.set(e.pointerId,{kind,el,x:e.clientX,y:e.clientY,startX:e.clientX,startY:e.clientY,time:e.timeStamp,dragged:false});
      el.setPointerCapture(e.pointerId);
      return true;
    }
    function moveStick(e) {
      const box=stick.getBoundingClientRect(),r=box.width*.34;
      let x=e.clientX-box.left-box.width/2,y=e.clientY-box.top-box.height/2;
      const length=Math.hypot(x,y),scale=Math.min(1,r/Math.max(1,length));x*=scale;y*=scale;
      const magnitude=Math.min(1,length/r),speed=magnitude<.12?0:(magnitude-.12)/.88;
      strafe=length && speed?x/Math.max(1,Math.hypot(x,y))*speed:0;
      forward=length && speed?-y/Math.max(1,Math.hypot(x,y))*speed:0;
      knob.style.transform=`translate(${x}px,${y}px)`;
    }
    stick.addEventListener('pointerdown',e=>{if(begin(e,'move',stick))moveStick(e);});
    const canvas=$('bevy-canvas');
    // A short tap fires on release; dragging only looks. A second finger can
    // tap the view while the first keeps aiming, independently of the stick.
    canvas.addEventListener('pointerdown',e=>begin(e,[...pointers.values()].some(p=>p.kind==='look')?'tap':'look',canvas));
    for(const [id,kind] of [['touch-fire','fire'],['touch-defuse','defuse']]) {
      const el=$(id);
      el.addEventListener('pointerdown',e=>{
        if(begin(e,kind,el)) {
          if(kind==='fire'){fire=true;firePressed=true;}else defuse=true;
        }
      });
    }
    document.addEventListener('pointermove',e=>{
      const p=pointers.get(e.pointerId);if(!p)return;
      if(!active()){reset();return;}
      e.preventDefault();
      if(Math.hypot(e.clientX-p.startX,e.clientY-p.startY)>12)p.dragged=true;
      if(p.kind==='move')moveStick(e);
      if(p.kind==='look' || p.kind==='fire') {
        lookX+=(e.clientX-p.x)*1.7;lookY+=(e.clientY-p.y)*1.7;
      }
      p.x=e.clientX;p.y=e.clientY;
    },{passive:false});
    const end=e=>{
      const p=pointers.get(e.pointerId);if(!p)return;pointers.delete(e.pointerId);
      if((p.kind==='look'||p.kind==='tap') && e.type==='pointerup' && active() && !p.dragged &&
          Math.hypot(e.clientX-p.startX,e.clientY-p.startY)<=12 && e.timeStamp-p.time<=280)firePressed=true;
      if(p.kind==='move'){forward=strafe=0;knob.style.transform='translate(0px,0px)';}
      if(p.kind==='fire')fire=false;
      if(p.kind==='defuse')defuse=false;
    };
    for(const event of ['pointerup','pointercancel','lostpointercapture'])document.addEventListener(event,end);
    $('touch-aim').addEventListener('click',()=>{if(active()){aim=!aim;$('touch-aim').setAttribute('aria-pressed',String(aim));}});
    $('touch-crouch').addEventListener('click',()=>{if(active()){crouch=!crouch;$('touch-crouch').setAttribute('aria-pressed',String(crouch));}});
    for(const [id,action] of [['touch-reload',reload],['touch-pause',pause],['touch-buy',shop],['touch-spectate',spectate]])
      $(id).addEventListener('click',()=>{if(active())action();});
    window.addEventListener('resize',reset);
    return {reset,read(){
      // Hold for one engine input packet too: automatic weapons use held fire,
      // semi-automatic weapons use the press edge. Never leave a tap held down.
      const value={forward,strafe,lookX,lookY,fire:fire||firePressed,firePressed,aim,crouch,defuse};
      lookX=lookY=0;firePressed=false;return value;
    }};
  };
})();
