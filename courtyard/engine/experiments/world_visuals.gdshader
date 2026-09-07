shader_type spatial;
render_mode diffuse_burley;

// Original procedural limewash/limestone treatment over existing Poly Haven
// CC0 mineral textures. Opaque, undisplaced, three texture reads, one pass.
uniform vec4 tint : source_color = vec4(0.82, 0.78, 0.69, 1.0);
uniform vec4 base_tint : source_color = vec4(0.55, 0.53, 0.47, 1.0);
uniform sampler2D diffuse_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D arm_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float texture_scale = 0.55;
uniform float normal_strength = 0.32;
uniform float masonry = 0.0;
uniform bool floor_surface = false;
varying vec3 world_position;
varying vec3 world_normal;

// No sine/noise loop or extra texture for subtle cut-stone block variation.
float stone_variation(vec2 cell) {
	vec3 p = fract(vec3(cell.xyx) * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec3 t = abs(n.y) > 0.6 ? vec3(1.0, 0.0, 0.0) : (abs(n.z) > abs(n.x) ? vec3(sign(n.z), 0.0, 0.0) : vec3(0.0, 0.0, -sign(n.x)));
	t = normalize(t - n * dot(n, t));
	vec3 b = normalize(cross(n, t));
	vec2 metres = vec2(dot(world_position, t), dot(world_position, b));
	vec2 uv = metres * texture_scale;
	vec3 mineral = texture(diffuse_map, uv).rgb;
	vec2 xy = texture(normal_map, uv).rg * 2.0 - 1.0;
	vec3 arm = texture(arm_map, uv).rgb;
	float luma = dot(mineral, vec3(0.2126, 0.7152, 0.0722));
	// Keep mineral variation, without importing the photograph's brown cast
	// into every wall. Paving retains more colour and close-range texture.
	vec3 grain = mix(vec3(luma), mineral, floor_surface ? 0.28 : 0.08);
	grain = mix(vec3(0.60), grain, floor_surface ? 0.90 : 0.52);
	vec3 pigment = tint.rgb * grain;
	if (!floor_surface) {
		// Soft wind-blown wear follows the existing two courtyard ramps. This
		// changes pigment only: never collision, vertex height or navigation.
		float south = 1.6 * clamp((world_position.z - 14.0) / 14.0, 0.0, 1.0);
		float ramp = 2.2 * clamp((world_position.x - 4.0) / 8.0, 0.0, 1.0) * clamp((-world_position.z - 2.0) / 20.0, 0.0, 1.0);
		float height = world_position.y - max(south, ramp);
		float wear = (1.0 - smoothstep(0.16, 1.30, height + (luma - 0.5) * 0.32));
		wear *= 1.0 - smoothstep(0.55, 0.78, abs(n.y));
		pigment = mix(pigment, base_tint.rgb * grain, wear * 0.72);
	}
	if (masonry > 0.0) {
		vec2 course = metres * vec2(1.15, 2.5);
		course.x += mod(floor(course.y), 2.0) * 0.5;
		vec2 edge = min(fract(course), 1.0 - fract(course));
		float footprint = max(fwidth(course.x), fwidth(course.y));
		float joint = 1.0 - smoothstep(0.012, 0.025 + footprint, min(edge.x, edge.y));
		joint *= 1.0 - smoothstep(0.12, 0.45, footprint);
		pigment *= mix(1.0, 0.91 + stone_variation(floor(course)) * 0.16, masonry);
		pigment = mix(pigment, pigment * 0.63, joint * masonry * 0.72);
	}
	vec3 detail = vec3(xy, sqrt(max(0.0001, 1.0 - dot(xy, xy))));
	vec3 perturbed = normalize(n * detail.z + (t * detail.x + b * detail.y) * normal_strength);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	ALBEDO = pigment;
	ROUGHNESS = (floor_surface ? 0.82 : 0.88) + arm.g * (floor_surface ? 0.16 : 0.10);
	SPECULAR = 0.28;
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.3;
}
