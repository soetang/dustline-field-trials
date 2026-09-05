'use strict';
const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
// Cargo metadata unions features across targets, even with --filter-platform.
// Inspect the actual target's dependency tree instead of that overbroad union.
const tree=execFileSync('cargo',['tree','--locked','--target','wasm32-unknown-unknown','-e','normal','--prefix','none','--format','{p}'],{encoding:'utf8'});
const crates=new Set(tree.trim().split('\n').map(line=>line.split(' ')[0]));
for(const required of ['bevy_pbr','bevy_gltf','bevy_world_serialization','bevy_winit','bevy_core_pipeline','bevy_image']) {
  assert.ok(crates.has(required),`Keep the game's required renderer subsystem: ${required}`);
}
for(const unused of ['bevy_audio','bevy_ui','bevy_text','bevy_animation','bevy_gizmos','bevy_picking','bevy_post_process','bevy_sprite_render','bevy_gilrs']) {
  assert.ok(!crates.has(unused),`Unused browser subsystem added to the engine download: ${unused}`);
}
console.log(`Lean browser engine verified: ${crates.size} runtime dependency names, required 3D/model systems retained, unused UI/audio/2D/picking systems excluded.`);
