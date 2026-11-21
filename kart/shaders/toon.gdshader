// Comic cel material for props, karts and pilots.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, hint_default_white;
uniform bool use_tex = false;
uniform bool use_vertex_color = false;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

#include "res://shaders/toon_light.gdshaderinc"

void fragment() {
	vec4 c = albedo;
	if (use_tex) {
		c *= texture(albedo_tex, UV);
	}
	if (use_vertex_color) {
		// Lift near-black plastics to a readable comic ink-blue so karts never turn into blobs.
		vec3 vc = COLOR.rgb;
		float lum = max(vc.r, max(vc.g, vc.b));
		vc = mix(vc, vec3(0.075, 0.07, 0.11), 1.0 - smoothstep(0.03, 0.09, lum));
		c.rgb *= vc;
	}
	ALBEDO = c.rgb;
	EMISSION = emission_color.rgb;
	ROUGHNESS = 1.0;
}
