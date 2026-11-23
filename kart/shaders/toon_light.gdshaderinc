// Shared comic lighting: 2-band cel diffuse, halftone dots in shade, hard
// specular pop and rim. #include in a spatial shader (provides light()).
uniform vec4 shade_color : source_color = vec4(0.7, 0.65, 0.86, 1.0);
uniform float shade_threshold = 0.3;
uniform float shade_softness = 0.03;
uniform float halftone_scale = 6.0;
uniform float halftone_strength = 0.32;
uniform float spec_size = 0.0;      // 0 = none; ~0.93 = glossy toy plastic
uniform float rim_strength = 0.2;

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float lit = smoothstep(shade_threshold - shade_softness, shade_threshold + shade_softness, ndl * ATTENUATION);
	vec2 cell = mat2(vec2(0.707, -0.707), vec2(0.707, 0.707)) * (FRAGCOORD.xy / halftone_scale);
	vec2 g = fract(cell) - 0.5;
	float dot_r = clamp((1.0 - lit) * (0.75 - ndl * 0.75), 0.0, 1.0) * 0.6;
	float dots = 1.0 - smoothstep(dot_r - 0.05, dot_r + 0.05, length(g));
	vec3 shade = ALBEDO * shade_color.rgb * (1.0 - halftone_strength * dots);
	vec3 col = mix(shade, ALBEDO, lit) * LIGHT_COLOR / PI;
	if (spec_size > 0.0) {
		vec3 h = normalize(LIGHT + VIEW);
		col += vec3(step(spec_size, dot(NORMAL, h)) * lit) * LIGHT_COLOR / PI * 0.7;
	}
	col += vec3(step(0.74, 1.0 - dot(NORMAL, VIEW)) * lit * rim_strength) * LIGHT_COLOR / PI;
	DIFFUSE_LIGHT += col;
}
