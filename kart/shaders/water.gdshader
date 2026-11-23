// Cartoon ocean: flat bands, wobbling foam stripes near the shore.
shader_type spatial;
render_mode unshaded;

uniform vec4 deep : source_color = vec4(0.1, 0.45, 0.85, 1.0);
uniform vec4 shallow : source_color = vec4(0.2, 0.78, 0.92, 1.0);
uniform vec4 foam : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec2 center = vec2(0.0);
uniform float shore_radius = 200.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }

void fragment() {
	float r = distance(wpos.xz, center);
	float a = atan(wpos.z - center.y, wpos.x - center.x);
	float wob = sin(a * 9.0 + TIME * 0.8) * 1.6 + sin(a * 23.0 - TIME * 1.3) * 0.7;
	float d = r - shore_radius + wob;
	vec3 c = mix(shallow.rgb, deep.rgb, step(30.0, d));
	float f1 = step(abs(d - 3.0 - sin(TIME * 1.2) * 1.5), 0.9);
	float f2 = step(abs(d - 12.0 - sin(TIME * 0.9 + 1.0) * 2.0), 0.6);
	c = mix(c, foam.rgb, max(f1, f2));
	// Little glints.
	vec2 cell = floor(wpos.xz / 6.0);
	float g = step(0.97, hash(cell)) * step(0.5, sin(TIME * 2.0 + hash(cell + 3.0) * 6.28));
	c = mix(c, foam.rgb, g * step(30.0, d) * 0.8);
	ALBEDO = c;
}
