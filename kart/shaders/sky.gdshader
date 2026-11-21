// Flat comic sky: banded gradient, cartoon sun, puffy stylized clouds.
shader_type sky;

uniform vec4 top : source_color = vec4(0.16, 0.5, 0.95, 1.0);
uniform vec4 horizon : source_color = vec4(0.62, 0.88, 1.0, 1.0);
uniform vec4 bottom : source_color = vec4(0.45, 0.75, 0.9, 1.0);
uniform vec4 cloud_col : source_color = vec4(1.0, 0.98, 0.93, 1.0);
uniform vec4 cloud_shade : source_color = vec4(0.72, 0.8, 0.98, 1.0);

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { float v = 0.0; float a = 0.5; for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; } return v; }

void sky() {
	float y = EYEDIR.y;
	float t = smoothstep(0.0, 0.55, y);
	t = floor(t * 4.0) / 4.0;   // posterized bands
	vec3 col = mix(horizon.rgb, top.rgb, t);
	if (y < 0.0) col = bottom.rgb;
	// Sun disk with ink ring.
	float sd = distance(EYEDIR, LIGHT0_DIRECTION);
	col = mix(col, vec3(1.0, 0.95, 0.6), step(sd, 0.07));
	col = mix(col, vec3(0.078, 0.063, 0.094), step(0.07, sd) * step(sd, 0.078));
	// Clouds.
	if (y > 0.02) {
		vec2 uv = EYEDIR.xz / (y + 0.15) * 1.4 + vec2(TIME * 0.006, 0.0);
		float n = fbm(uv);
		float c = step(0.56, n) * smoothstep(0.02, 0.2, y);
		float cs = step(0.56, fbm(uv + vec2(0.03, 0.06)));
		vec3 cc = mix(cloud_shade.rgb, cloud_col.rgb, cs);
		float rim = step(0.53, n) * (1.0 - step(0.56, n)) * smoothstep(0.02, 0.2, y);
		col = mix(col, cc, c);
		col = mix(col, vec3(0.078, 0.063, 0.094), rim * 0.85);
	}
	COLOR = col;
}
