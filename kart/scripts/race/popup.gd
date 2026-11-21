class_name ComicPopup
extends Label3D
## "POW!"-style comic onomatopoeia that pops, wobbles and fades.

var _t := 0.0
const LIFE := 0.9


func setup(text_value: String, color: Color) -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	text = text_value
	font = Game.FONT_TITLE
	font_size = 160
	pixel_size = 0.006
	outline_size = 36
	outline_modulate = Game.INK
	modulate = color
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	no_depth_test = true
	render_priority = 10
	outline_render_priority = 9
	rotation.z = randf_range(-0.25, 0.25)
	scale = Vector3.ONE * 0.2


func _process(delta: float) -> void:
	_t += delta
	var k := _t / LIFE
	var s := 0.2 + (1.0 - pow(1.0 - minf(k * 4.0, 1.0), 3.0)) * 1.0
	if k > 0.7:
		s *= 1.0 - (k - 0.7) / 0.3 * 0.4
		modulate.a = 1.0 - (k - 0.7) / 0.3
		outline_modulate.a = modulate.a
	scale = Vector3.ONE * s
	position.y += delta * 1.2
	if _t >= LIFE:
		queue_free()
