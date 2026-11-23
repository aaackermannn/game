// Track surfaces. UV.x = 0..1 across, UV.y = metres along the track.
// mode 0 = asphalt, 1 = kerb stripes, 2 = grass, 3 = sand, 4 = barrier blocks
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform int mode = 0;
uniform vec4 col_a : source_color = vec4(0.33, 0.33, 0.38, 1.0);
uniform vec4 col_b : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float stripe_len = 3.0;
uniform float track_length = 1000.0;

#include "res://shaders/toon_light.gdshaderinc"

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec3 c = col_a.rgb;
	if (mode == 0) {
		// Asphalt speckles.
		float h = hash(floor(UV * vec2(60.0, 6.0)));
		c *= 0.94 + 0.12 * step(0.85, h);
		// Edge lines.
		float edge = step(UV.x, 0.035) + step(0.965, UV.x);
		c = mix(c, col_b.rgb, edge);
		// Dashed centre line.
		float dash = step(abs(UV.x - 0.5), 0.012) * step(0.5, fract(UV.y / 8.0));
		c = mix(c, col_b.rgb * 0.95, dash);
		// Start/finish checker band.
		float d = mod(UV.y, track_length);
		if (d < 3.0 || d > track_length - 0.0) {
			float ck = mod(floor(UV.x * 14.0) + floor(d / 1.0), 2.0);
			c = mix(vec3(0.08, 0.06, 0.09), vec3(1.0), ck);
		}
		// Grid boxes behind the line.
		float gd = track_length - d;
		if (gd > 4.0 && gd < 70.0) {
			float row = mod(gd - 4.0, 7.0);
			float side = UV.x < 0.5 ? 0.25 : 0.75;
			float stag = UV.x < 0.5 ? 0.0 : 3.5;
			float r2 = mod(gd - 4.0 + stag, 7.0);
			float box = step(abs(UV.x - side), 0.13) * step(r2, 0.25);
			c = mix(c, col_b.rgb, box);
		}
	} else if (mode == 1) {
		float s = step(0.5, fract(UV.y / stripe_len));
		c = mix(col_a.rgb, col_b.rgb, s);
	} else if (mode == 2) {
		float band = step(0.5, fract(UV.y / 9.0));
		c = mix(col_a.rgb, col_a.rgb * 1.08, band);
		float tuft = step(0.93, hash(floor(UV * vec2(40.0, 1.5))));
		c = mix(c, col_a.rgb * 0.8, tuft);
	} else if (mode == 3) {
		float h = step(0.9, hash(floor(UV * vec2(90.0, 3.0))));
		c *= 1.0 - 0.08 * h;
	} else if (mode == 4) {
		float s = step(0.5, fract(UV.y / stripe_len));
		c = mix(col_a.rgb, col_b.rgb, s);
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
}
