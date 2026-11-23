class_name Toon
## Helpers that turn everything into the comic look.

const TOON_SHADER := preload("res://shaders/toon.gdshader")
const ROAD_SHADER := preload("res://shaders/road.gdshader")
const INK_SHADER := preload("res://shaders/ink_post.gdshader")

static var _cache := {}
const FACE_MATS := ["skin", "white", "iris", "lash", "mouth", "tongue", "hair", "eye"]


static func mat(color: Color, glossy := false, emission := Color.BLACK, vertex_color := false) -> ShaderMaterial:
	var key := "%s|%s|%s|%s" % [color.to_html(), glossy, emission.to_html(), vertex_color]
	if _cache.has(key):
		return _cache[key]
	var m := ShaderMaterial.new()
	m.shader = TOON_SHADER
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("spec_size", 0.93 if glossy else 0.0)
	m.set_shader_parameter("emission_color", emission)
	m.set_shader_parameter("use_vertex_color", vertex_color)
	_cache[key] = m
	return m


static func surface(mode: int, a: Color, b := Color.WHITE, stripe := 3.0, track_len := 1000.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ROAD_SHADER
	m.set_shader_parameter("mode", mode)
	m.set_shader_parameter("col_a", a)
	m.set_shader_parameter("col_b", b)
	m.set_shader_parameter("stripe_len", stripe)
	m.set_shader_parameter("track_length", track_len)
	return m


## Replace imported (glTF) materials with toon ones that keep their colors.
## `recolor` maps material-name substrings (lowercase) to replacement colors,
## which is how one kart model gets every racer's livery.
static func apply(root: Node, recolor := {}) -> void:
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(s)
			if src == null:
				src = mi.mesh.surface_get_material(s)
			var color := Color(0.8, 0.8, 0.8)
			var glossy := false
			var emission := Color.BLACK
			var mat_name := ""
			var vcol := false
			if mi.mesh is ArrayMesh:
				vcol = ((mi.mesh as ArrayMesh).surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR) != 0
			if src:
				mat_name = src.resource_name.to_lower()
			if src is BaseMaterial3D:
				var bm := src as BaseMaterial3D
				color = bm.albedo_color
				vcol = vcol or bm.vertex_color_use_as_albedo
				glossy = bm.roughness < 0.45
				if bm.emission_enabled:
					emission = bm.emission * bm.emission_energy_multiplier
			for key in recolor:
				if mat_name.contains(key):
					color = recolor[key]
			# Faces stay bright and clean: self-lit share, no murky halftone.
			for face_key in FACE_MATS:
				if mat_name.begins_with(face_key):
					emission = color * 0.45
					break
			mi.set_surface_override_material(s, mat(color, glossy, emission, vcol))


static func ink_overlay() -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	var m := ShaderMaterial.new()
	m.shader = INK_SHADER
	m.render_priority = 100
	quad.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "InkOverlay"
	return mi
