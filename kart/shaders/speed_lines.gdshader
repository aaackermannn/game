// Comic speed lines overlay (CanvasItem on a full-screen ColorRect).
shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec4 line_col : source_color = vec4(1.0, 1.0, 1.0, 1.0);

float hash(float n) { return fract(sin(n) * 43758.5453); }

void fragment() {
	vec2 p = UV - vec2(0.5, 0.55);
	p.x *= 1.777;
	float a = atan(p.y, p.x);
	float r = length(p);
	float seg = floor(a * 40.0);
	float h = hash(seg + floor(TIME * 18.0) * 13.0);
	float w = fract(a * 40.0);
	float line = step(0.82, h) * step(0.35, w) * step(w, 0.65);
	float mask = smoothstep(0.32, 0.75, r);
	COLOR = vec4(line_col.rgb, line * mask * intensity * 0.75);
}
