'use strict';
const assert = require('node:assert/strict');
const {comparePair,validateStages,validateSleepStages,compareSleepImages,validateDeathWallStages,NAMES,DEATH_WALL_NAMES} = require('./compare-operator-reviews');
let checks=0;
const check=fn=>{fn();checks++;};
const original={name:'ct-walk-first',build:'fixture',actor_position:[0,0,0],actor_yaw:0,weapon_clear:true,weapon_withdrawal:0,companions:[],
  render:{quality:'High',ssao:true,scale_3d:1,viewport_pixels:[40,40],primitives:1234,draw_calls:100},
  skin:{palette_valid:true,bones:18,bindings:18,poses:Array(18).fill([1,2,3]),palette:Array(18).fill([4,5,6]),model_transform:[7,8,9]}};
const candidate=structuredClone(original);
candidate.render.draw_calls=94;
candidate.skin.bindings=54;
const image={width:40,height:40,data:Buffer.alloc(40*40*4,128)};
check(()=>assert.deepEqual(comparePair(original,candidate,image,image),
  {name:'ct-walk-first',draw_calls_saved:6,primitives:1234,changed_pixels:0,maximum_channel_difference:0}));
const reject=(change,pattern)=>check(()=>{const value=structuredClone(candidate);change(value);assert.throws(()=>comparePair(original,value,image,image),pattern);});
reject(value=>value.skin.palette_valid=false,/false/);
reject(value=>value.skin.palette[0]=[0,0,0],/same palette/);
reject(value=>value.skin.poses[0]=[0,0,0],/same poses/);
reject(value=>value.skin.bindings=18,/18/);
reject(value=>value.skin.bones=54,/54/);
reject(value=>value.skin.model_transform=[0,0,0],/same model_transform/);
reject(value=>value.render.primitives--,/same primitives/);
reject(value=>value.render.draw_calls=100,/draw calls decrease/);
reject(value=>value.render.scale_3d=0.75,/same scale_3d/);
reject(value=>value.weapon_clear=false,/same weapon_clear/);
reject(value=>value.actor_position[0]=1,/same actor_position/);
const altered={...image,data:Buffer.from(image.data)};
altered.data[0]++;
check(()=>assert.equal(comparePair(original,candidate,image,altered).changed_pixels,1));
altered.data[0]++;
check(()=>assert.throws(()=>comparePair(original,candidate,image,altered),/maximum pixel difference/));
altered.data[0]--;
altered.data[4]++;
altered.data[8]++;
check(()=>assert.throws(()=>comparePair(original,candidate,image,altered),/changed pixels/));
const stages=NAMES.map((name,index)=>{
  const capture=structuredClone(original);
  capture.name=name;
  capture.skin.poses[0]=[index];
  capture.skin.palette[0]=[index];
  capture.skin.palette_rid='primary';
  if (name.includes('squad')) capture.companions=[1,2].map(id=>({position:[id,0,0],yaw:0,
    skin:{...structuredClone(capture.skin),palette_rid:String(id),palette:Array(18).fill([id+20])}}));
  return capture;
});
const sleepEntry=stages[15];
sleepEntry.sleep={sleeping:true,corpse_time:1,settle_ticks:60,process_calls:60,held_frames:0,
  skeleton_updates:1,health:0,paused:true,game_elapsed:0};
stages[16]={...structuredClone(sleepEntry),name:'ct-sleep-hold',
  sleep:{...sleepEntry.sleep,process_calls:68,held_frames:8}};
stages[17]={...structuredClone(stages[16]),name:'ct-sleep-moved',actor_position:[0.2,0,0],
  sleep:{...stages[16].sleep,sleeping:false,corpse_time:1/60,process_calls:69,skeleton_updates:2}};
const identity=[1,0,0,0,1,0,0,0,1,0,0,0];
for(const capture of stages.slice(18)) {
  const [,team,angle,phase]=capture.name.match(/^(ct|t)-wall-death-(into|oblique|parallel)-(falling|settled)$/);
  capture.actor_position=[-7.674,0,-33.478039];
  capture.skin.poses=Array.from({length:18},()=>[...identity]);
  capture.skin.palette=Array.from({length:18},()=>[...identity]);
  capture.skin.model_transform=[...identity];
  capture.death_wall={schema:1,team,angle_degrees:{into:0,oblique:45,parallel:90}[angle],phase,
    prewarm_ticks:60,starting_withdrawal:0.9,starting_cached_clear:true,death_ticks:phase==='falling' ? 8 : 60,
    health:0,paused:true,fall:phase==='falling' ? 0.32 : 1,sleeping:phase==='settled',
    wall:{found:true,body_class:'StaticBody3D',shape_class:'BoxShape3D',point:[-8,1.4,-33.478039],normal:[1,0,0],shape_size:[1,4,10]},
    capsule:{shape_class:'CapsuleShape3D',radius:0.32,height:1.8,center_distance_m:0.326,wall_margin_m:0.006,overlaps:0},
    weapon:{bounds_position:[0,0,0],bounds_size:[0.2,0.3,0.7],shape_size:[0.31,0.41,0.81],
      hull_transform:[...identity],hull_overlaps:0,connection_clear:true,grip_error_m:[0.001,0.002]},
    vertices:{body_count:100,weapon_count:30,body_min_wall_m:-0.2,weapon_min_wall_m:0.06},measurement:'fixture diagnostic'};
}
check(()=>validateStages(stages));
check(()=>assert.throws(()=>validateStages(stages.slice(0,-1)),/stages captured/));
const frozen=structuredClone(stages);
frozen[1].skin.palette=frozen[0].skin.palette;
check(()=>assert.throws(()=>validateStages(frozen),/distinct palette/));
const shared=structuredClone(stages);
shared[12].companions[0].skin.palette_rid=shared[12].skin.palette_rid;
check(()=>assert.throws(()=>validateStages(shared),/Separate renderer palettes/));
const squadA=structuredClone(stages[12]),squadB=structuredClone(squadA);
squadB.render.draw_calls=82;
for (const skin of [squadB.skin,...squadB.companions.map(other=>other.skin)]) skin.bindings=54;
check(()=>assert.equal(comparePair(squadA,squadB,image,image).draw_calls_saved,18));
squadB.companions[1].skin.poses[0]=[99];
check(()=>assert.throws(()=>comparePair(squadA,squadB,image,image),/companion 1: same poses/));
const rejectSleep=(change,pattern)=>check(()=>{
  const value=structuredClone(stages);
  change(value[15],value[16],value[17]);
  assert.throws(()=>validateSleepStages(value),pattern);
});
rejectSleep(entry=>entry.sleep.sleeping=false,/reached sleep/);
rejectSleep((entry,hold,moved)=>{for(const stage of [entry,hold,moved]) stage.sleep.settle_ticks=59;},/60–180/);
rejectSleep((entry,hold,moved)=>{for(const stage of [entry,hold,moved]) stage.sleep.settle_ticks=181;},/60–180/);
rejectSleep(entry=>entry.sleep.corpse_time=0.99,/one-second settling/);
rejectSleep(entry=>entry.sleep.skeleton_updates=0,/pending skeleton updates/);
rejectSleep(entry=>entry.sleep.process_calls--,/every actual settling callback/);
rejectSleep((entry,hold)=>hold.sleep.sleeping=false,/remains asleep/);
rejectSleep((entry,hold)=>hold.sleep.held_frames=7,/Eight rendered hold frames/);
rejectSleep((entry,hold)=>hold.sleep.process_calls--,/every held frame/);
rejectSleep((entry,hold)=>hold.sleep.skeleton_updates++,/no additional skeleton_updated/);
rejectSleep((entry,hold)=>hold.sleep.corpse_time+=1/60,/does not advance/);
rejectSleep((entry,hold)=>hold.skin.poses[0]=[99],/preserves poses/);
rejectSleep((entry,hold)=>hold.skin.palette[0]=[99],/preserves palette/);
rejectSleep((entry,hold)=>hold.skin.model_transform=[99],/preserves model_transform/);
rejectSleep((entry,hold)=>hold.skin.palette_rid='new-palette',/same registered palette/);
rejectSleep((entry,hold)=>hold.actor_position[0]=0.1,/preserves actor_position/);
rejectSleep((entry,hold)=>hold.render.draw_calls--,/preserves rendered draw_calls/);
rejectSleep((entry,hold)=>hold.sleep.paused=false,/match is paused/);
rejectSleep((entry,hold)=>hold.sleep.game_elapsed+=1/60,/No live match ticks/);
rejectSleep((entry,hold)=>hold.companions=[{}],/Only the corpse/);
rejectSleep((entry,hold,moved)=>moved.sleep.sleeping=true,/wakes animation/);
rejectSleep((entry,hold,moved)=>moved.sleep.process_calls++,/one actual wake callback/);
rejectSleep((entry,hold,moved)=>moved.sleep.skeleton_updates=hold.sleep.skeleton_updates,/another skeleton_updated/);
rejectSleep((entry,hold,moved)=>moved.sleep.corpse_time=hold.sleep.corpse_time,/fresh settling interval/);
rejectSleep((entry,hold,moved)=>moved.actor_position[0]=0.1,/exactly 0.2 m/);
const movedImage={...image,data:Buffer.from(image.data)};
movedImage.data[0]++;
const readSleepImage=name=>name==='ct-sleep-moved' ? movedImage : image;
check(()=>assert.deepEqual(compareSleepImages(stages,readSleepImage),{held_frames:8,skeleton_updates_while_sleeping:0,
  skeleton_updates_on_wake:1,settle_ticks:60,entry_hold_pixel_exact:true,moved_pixels_changed:true}));
check(()=>assert.throws(()=>compareSleepImages(stages,name=>name==='ct-sleep-entry' ? image : movedImage),/pixels must be exactly equal/));
check(()=>assert.throws(()=>compareSleepImages(stages,()=>image),/must visibly update/));
check(()=>assert.throws(()=>compareSleepImages(stages,()=>({...image,width:39})),/dimensions match/));
check(()=>assert.throws(()=>compareSleepImages(stages,()=>({...image,data:Buffer.alloc(4)})),/6400/));
const sleepCandidate=structuredClone(sleepEntry);
sleepCandidate.skin.bindings=54;
sleepCandidate.render.draw_calls=94;
check(()=>assert.equal(comparePair(sleepEntry,sleepCandidate,image,image).changed_pixels,0));
sleepCandidate.sleep.skeleton_updates++;
check(()=>assert.throws(()=>comparePair(sleepEntry,sleepCandidate,image,image),/same corpse sleep metadata/));
check(()=>assert.equal(NAMES.length,30));
check(()=>assert.equal(validateDeathWallStages(stages).length,12));
check(()=>assert.throws(()=>validateDeathWallStages(stages.slice(0,-1)),/All twelve/));
const rejectDeath=(change,pattern)=>check(()=>{
  const value=structuredClone(stages);change(value[18],value[18].death_wall);
  assert.throws(()=>validateDeathWallStages(value),pattern);
});
rejectDeath(capture=>delete capture.death_wall,/schema/);
rejectDeath((capture,value)=>value.prewarm_ticks=0,/live wall contact/);
rejectDeath((capture,value)=>delete value.starting_cached_clear,/prewarm clearance/);
rejectDeath((capture,value)=>value.starting_withdrawal=NaN,/prewarm withdrawal/);
rejectDeath((capture,value)=>value.death_ticks=7,/death callbacks/);
rejectDeath((capture,value)=>value.angle_degrees=30,/45|0|30/);
rejectDeath((capture,value)=>value.fall=1,/falling\/settled/);
rejectDeath((capture,value)=>value.wall.found=false,/map wall/);
rejectDeath((capture,value)=>value.wall.shape_class='SphereShape3D',/BoxShape3D/);
rejectDeath((capture,value)=>value.wall.shape_size=[1,NaN,1],/Finite wall shape/);
rejectDeath((capture,value)=>value.capsule.radius=0.476,/capsule dimensions/);
rejectDeath((capture,value)=>value.capsule.center_distance_m=0.476,/capsule placement/);
rejectDeath(capture=>capture.actor_position[0]+=0.1,/captured actor/);
rejectDeath((capture,value)=>value.weapon.shape_size[0]+=0.1,/padded weapon hull/);
rejectDeath((capture,value)=>value.weapon.hull_transform=[0],/Finite gun hull transform/);
rejectDeath((capture,value)=>value.weapon.grip_error_m=[NaN,0],/hand-grip errors/);
rejectDeath((capture,value)=>value.vertices.body_count=0,/Both body and weapon/);
rejectDeath((capture,value)=>value.vertices.weapon_min_wall_m=Infinity,/Finite weapon_min_wall/);
rejectDeath(capture=>capture.skin.palette_valid=false,/palette is valid/);
rejectDeath(capture=>capture.skin.palette[0][0]=NaN,/Finite palette transform/);
// Existing penetration/grip problems must stay visible, not prevent artifacts.
const problem=structuredClone(stages);
problem[18].weapon_clear=false;
Object.assign(problem[18].death_wall.weapon,{hull_overlaps:3,connection_clear:false,grip_error_m:[0.2,0.3]});
problem[18].death_wall.vertices.weapon_min_wall_m=-0.4;
problem[19].death_wall.sleeping=false;
check(()=>{
  const report=validateDeathWallStages(problem);
  assert.equal(report[0].hull_overlaps,3);assert.equal(report[0].connection_clear,false);
  assert.equal(report[0].weapon_min_wall_m,-0.4);assert.equal(report[1].sleeping,false);
});
const deathA=structuredClone(stages[18]),deathB=structuredClone(deathA);
deathB.skin.bindings=54;deathB.render.draw_calls=94;
check(()=>assert.equal(comparePair(deathA,deathB,image,image).changed_pixels,0));
deathB.death_wall.weapon.grip_error_m[0]+=0.001;
check(()=>assert.throws(()=>comparePair(deathA,deathB,image,image),/same wall-death diagnostics/));
check(()=>assert.deepEqual(stages.slice(18).map(capture=>capture.name),DEATH_WALL_NAMES));
check(()=>{
  const leaked=structuredClone(stages);leaked[0].death_wall=leaked[18].death_wall;
  assert.throws(()=>validateStages(leaked),/reserved for diagnostic stages/);
});
console.log(`OPERATOR_REVIEW_COMPARISON: ${checks}/${checks} passed`);
