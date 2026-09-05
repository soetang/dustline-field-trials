shader_type spatial;
render_mode diffuse_burley;

uniform vec4 tint : source_color = vec4(0.8, 0.7, 0.55, 1.0);
uniform sampler2D diffuse_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D arm_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float texture_scale = 0.25;
uniform float normal_strength = 0.5;
varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 n = normalize(world_normal);
	// Dominant-axis projection suits the authored walls/ramps: three texture
	// fetches, rather than sampling every texture three times for triplanar.
	vec3 t = abs(n.y) > 0.6 ? vec3(1.0, 0.0, 0.0) : (abs(n.z) > abs(n.x) ? vec3(sign(n.z), 0.0, 0.0) : vec3(0.0, 0.0, -sign(n.x)));
	t = normalize(t - n * dot(n, t));
	vec3 b = normalize(cross(n, t));
	vec2 uv = vec2(dot(world_position, t), dot(world_position, b)) * texture_scale;
	vec2 xy = texture(normal_map, uv).rg * 2.0 - 1.0;
	vec3 detail = vec3(xy, sqrt(max(0.0001, 1.0 - dot(xy, xy))));
	vec3 perturbed = normalize(n * detail.z + (t * detail.x + b * detail.y) * normal_strength);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	vec3 arm = texture(arm_map, uv).rgb;
	ALBEDO = tint.rgb * texture(diffuse_map, uv).rgb;
	ROUGHNESS = 0.74 + arm.g * 0.25; // Dry plaster/concrete, not glossy metal.
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.3;
}
