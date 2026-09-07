shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Only the default opaque, textureless StandardMaterial3D configuration is
// accepted by operator_surface.gd. COLOR is already linear glTF vertex color.
// UV is constant within each source-material triangle, never a texture lookup.
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = UV.x;
	METALLIC = UV.y;
	SPECULAR = 0.5;
}
