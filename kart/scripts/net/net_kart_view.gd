class_name NetKartView
extends Node3D
## What a NET LAB kart looks like on screen. Pure presentation: it is told a
## NetSim.State and draws it — it never decides where the kart is.

var slot := 0
var _visual: Node3D
var _flame: MeshInstance3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _tag: Label3D
var _pop: Label3D
var _pop_t := 0.0
var _tag_color := Game.PAPER
var _prev_cooldown := 0


func setup(p_slot: int, caption: String, color: Color) -> void:
	slot = p_slot
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var racer: Dictionary = Game.ROSTER[slot % Game.ROSTER.size()]
	_visual = Node3D.new()
	add_child(_visual)
	_visual.add_child(Props.make_kart(racer, slot % Game.ROSTER.size()))

	# Dash flame: a stretched cone behind the kart, only visible during the burst.
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.55
	cone.height = 2.6
	_flame = MeshInstance3D.new()
	_flame.mesh = cone
	_flame.material_override = _unshaded(Color("ffb21f"), 0.9)
	_flame.rotation.x = -PI * 0.5
	_flame.position = Vector3(0, 0.55, 2.4)
	_flame.visible = false
	add_child(_flame)

	# Cooldown ring on the ground: bright when the dash is ready.
	var torus := TorusMesh.new()
	torus.inner_radius = 1.55
	torus.outer_radius = 1.85
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring_mat = _unshaded(color, 0.85)
	_ring.material_override = _ring_mat
	_ring.scale = Vector3(1, 0.15, 1)
	_ring.position.y = 0.06
	add_child(_ring)

	_tag_color = color
	_tag = _label(caption, 54, color)
	_tag.position = Vector3(0, 2.7, 0)
	add_child(_tag)
	_pop = _label("", 70, Game.YELLOW)
	_pop.position = Vector3(0, 4.0, 0)
	_pop.visible = false
	add_child(_pop)


func show_state(s: NetSim.State, offset := Vector2.ZERO) -> void:
	position = Vector3(s.pos.x + offset.x, 0.0, s.pos.y + offset.y)
	rotation.y = s.heading
	var dashing := s.dash_ticks > 0
	_flame.visible = dashing
	# A new dash = the cooldown jumped up (works even if the burst itself was
	# already over when the server's state arrived).
	if s.cooldown_ticks > _prev_cooldown + 10:
		pop("DASH!", Game.YELLOW)
	_prev_cooldown = s.cooldown_ticks
	var ready := s.cooldown_ticks == 0
	_ring_mat.albedo_color = Color(_tag_color, 0.9) if ready else Color(0.35, 0.35, 0.4, 0.5)
	var k := 1.0 - float(s.cooldown_ticks) / NetSim.DASH_COOLDOWN_TICKS
	_ring.scale = Vector3(lerpf(0.45, 1.0, k), 0.15, lerpf(0.45, 1.0, k))


func pop(text: String, color: Color) -> void:
	_pop.text = text
	_pop.modulate = color
	_pop.visible = true
	_pop_t = 0.7


func _process(delta: float) -> void:
	if _pop_t > 0.0:
		_pop_t -= delta
		_pop.position.y = 4.0 + (0.7 - _pop_t) * 1.5
		if _pop_t <= 0.0:
			_pop.visible = false


static func _unshaded(c: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = 120  # draw after the ink post-process quad (priority 100)
	return m


static func _label(text: String, size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = Game.FONT_TITLE
	l.font_size = size
	l.outline_size = 14
	l.outline_modulate = Game.INK
	l.modulate = color
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.pixel_size = 0.01
	l.render_priority = 121
	l.outline_render_priority = 120
	return l


## Translucent marker showing where the SERVER says a kart is.
static func make_ghost() -> Node3D:
	var g := Node3D.new()
	g.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var torus := TorusMesh.new()
	torus.inner_radius = 1.0
	torus.outer_radius = 1.3
	var ring := MeshInstance3D.new()
	ring.mesh = torus
	ring.material_override = _unshaded(Game.CYAN, 0.75)
	ring.position.y = 0.1
	ring.scale = Vector3(1, 0.2, 1)
	g.add_child(ring)
	var arrow := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.35, 0.12, 1.6)
	arrow.mesh = box
	arrow.material_override = _unshaded(Game.CYAN, 0.75)
	arrow.position = Vector3(0, 0.12, -1.4)
	g.add_child(arrow)
	var tag := _label("SERVER", 40, Game.CYAN)
	tag.position = Vector3(0, 1.4, 0)
	g.add_child(tag)
	return g
