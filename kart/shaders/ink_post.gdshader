// Full-screen ink outlines from depth + normal edges. Put on a QuadMesh
// (size 2x2, flip_faces off) parented to the camera; covers the screen.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest;
uniform vec4 ink : source_color = vec4(0.078, 0.063, 0.094, 1.0);
uniform float thickness = 1.8;
uniform float depth_sens = 0.035;
uniform float normal_sens = 0.8;
uniform float max_dist = 180.0;
uniform float near_lod = 14.0;  // metres: full detail lines up to here
uniform float far_lod = 40.0;   // metres: silhouette-only, 1px lines beyond here

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float lin_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float d0 = lin_depth(uv, INV_PROJECTION_MATRIX);
	// Distance LOD: lines get thinner far away and inner detail lines drop out,
	// so distant karts keep a clean silhouette instead of turning into ink blobs.
	float far_t = smoothstep(near_lod, far_lod, d0);
	// Line width is authored for 900p; scale with resolution, never under 1px.
	float res_k = VIEWPORT_SIZE.y / 900.0;
	vec2 px = max(mix(thickness, 1.0, far_t) * res_k, 1.0) / VIEWPORT_SIZE;
	float dl = lin_depth(uv + vec2(-px.x, 0.0), INV_PROJECTION_MATRIX);
	float dr = lin_depth(uv + vec2(px.x, 0.0), INV_PROJECTION_MATRIX);
	float du = lin_depth(uv + vec2(0.0, -px.y), INV_PROJECTION_MATRIX);
	float dd = lin_depth(uv + vec2(0.0, px.y), INV_PROJECTION_MATRIX);
	// Second difference: flat slopes (grazing ground) cancel out, real silhouettes don't.
	float dedge = (abs(dl + dr - 2.0 * d0) + abs(du + dd - 2.0 * d0)) / max(d0, 0.5);
	float e_depth = step(depth_sens * mix(1.0, 4.0, far_t), dedge);
	// Far away, only ink the outer silhouette (pixel is in front of a much farther neighbour).
	float dmax = max(max(dl, dr), max(du, dd));
	float silhouette = step(d0 * 1.25 + 0.5, dmax);
	e_depth = mix(e_depth, e_depth * silhouette, far_t);

	vec3 n0 = texture(normal_tex, uv).xyz * 2.0 - 1.0;
	vec3 nl = texture(normal_tex, uv + vec2(-px.x, 0.0)).xyz * 2.0 - 1.0;
	vec3 nr = texture(normal_tex, uv + vec2(px.x, 0.0)).xyz * 2.0 - 1.0;
	vec3 nu = texture(normal_tex, uv + vec2(0.0, -px.y)).xyz * 2.0 - 1.0;
	vec3 nd = texture(normal_tex, uv + vec2(0.0, px.y)).xyz * 2.0 - 1.0;
	float nedge = distance(n0, nl) + distance(n0, nr) + distance(n0, nu) + distance(n0, nd);
	float e_norm = step(normal_sens, nedge) * (1.0 - far_t);

	float fade = 1.0 - smoothstep(max_dist * 0.6, max_dist, d0);
	float edge = max(e_depth, e_norm) * fade;
	vec3 col = texture(screen_tex, uv).rgb;
	ALBEDO = mix(col, ink.rgb, edge);
}
