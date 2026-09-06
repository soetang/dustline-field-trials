shader_type spatial;
render_mode diffuse_burley;

// Original prototype colors: alpha is a material selector, not transparency.
// No texture download, noise loop, per-frame geometry or extra material pass.
varying vec3 pigment;
void vertex() {
	pigment = COLOR.rgb;
	if (!OUTPUT_IS_SRGB) {
		pigment = mix(pigment / 12.92, pow((pigment + 0.055) / 1.055, vec3(2.4)), greaterThan(pigment, vec3(0.04045)));
	}
}
void fragment() {
	ALBEDO = pigment;
	METALLIC = COLOR.a;
	ROUGHNESS = mix(0.86, 0.48, COLOR.a);
	SPECULAR = 0.3;
}
