shader_type spatial;
render_mode diffuse_burley;
uniform vec4 tint : source_color = vec4(0.7, 0.59, 0.43, 1.0);
uniform float masonry = 0.0;
varying vec3 world;
varying vec3 surface_normal;
float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
	return mix(mix(mix(hash(i), hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);
}
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; surface_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL); }
void fragment() {
	float broad = noise(world * 0.42), grain = noise(world * 37.0);
	vec2 uv = abs(surface_normal.y) > 0.6 ? world.xz : (abs(surface_normal.z) > 0.6 ? world.xy : world.zy);
	uv *= vec2(1.25, 2.8); uv.x += mod(floor(uv.y), 2.0) * 0.5;
	vec2 edge = min(fract(uv), 1.0-fract(uv));
	float mortar = (1.0-smoothstep(0.012,0.035,min(edge.x,edge.y))) * masonry;
	float staining = smoothstep(0.35,0.75,noise(world * vec3(1.3,0.22,1.3))) * 0.10;
	ALBEDO = tint.rgb * (0.86 + broad*0.23 + grain*0.065 - staining - mortar*0.21);
	ROUGHNESS = 0.9;
}
