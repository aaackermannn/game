class_name MainMenu
extends Node3D
## Title screen: the island in the background, the chosen racer's kart on a
## turntable, and comic option buttons.

var _track: Track
var _cam: Camera3D
var _turntable: Node3D
var _kart_model: Node3D
var _racer_name: Label
var _rows := {}
var _t := 0.0


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # everything here moves per frame
	_build_world()
	_build_ui()
	_refresh()


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/sky.gdshader")
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.6, 0.75)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)
	_track = SunsetTrack.new()  # same circuit the race uses
	add_child(_track)
	_track.build()
	_turntable = Node3D.new()
	var t := _track.transform_at(_track.length - 20.0, 0.0)
	_turntable.position = t.origin
	add_child(_turntable)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	add_child(_cam)
	_cam.add_child(Toon.ink_overlay())
	_cam.make_current()


func _process(delta: float) -> void:
	_t += delta
	_turntable.rotation.y += delta * 0.6
	var f := _track.forward_at(_track.length - 20.0)
	var r := f.cross(Vector3.UP)
	var p := _turntable.position
	# Kart framed on the right third of the screen.
	_cam.position = p - f * 5.6 + r * -1.9 + Vector3.UP * 2.0
	_cam.look_at(p + r * -1.9 + Vector3.UP * 0.9, Vector3.UP)
	_cam.position += Vector3(sin(_t * 0.3) * 0.15, sin(_t * 0.5) * 0.08, 0)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)

	var title := Ui.label("LOOP GP", 150, Game.YELLOW, null, 22)
	title.position = Vector2(60, 14)
	title.rotation = deg_to_rad(-5)
	root.add_child(title)
	var sub := Ui.panel(Game.RED, 18.0, 14.0)
	sub.add_child(Ui.label("CHIBI FORMULA MAYHEM", 34, Game.PAPER, null, 7))
	sub.position = Vector2(84, 190)
	sub.rotation = deg_to_rad(-3)
	root.add_child(sub)

	var col := VBoxContainer.new()
	# Compact column: everything must fit above the hint line at 900 px height.
	col.position = Vector2(80, 268)
	col.custom_minimum_size = Vector2(430, 0)
	col.add_theme_constant_override("separation", 9)
	root.add_child(col)
	var race := Ui.button("RACE!", Game.YELLOW, 54)
	race.pressed.connect(func(): Game.main.start_race())
	col.add_child(race)
	_add_row(col, "racer", func(d): Game.player_racer = posmod(Game.player_racer + d, Game.ROSTER.size()))
	_add_row(col, "laps", func(d): Game.laps = posmod(Game.laps - 1 + d, 9) + 1)  # 1..9, wraps
	_add_row(col, "rivals", func(d): Game.bot_count = posmod(Game.bot_count + d, 8))  # 0..7, wraps
	_add_row(col, "difficulty", func(d): Game.difficulty = posmod(Game.difficulty + d, 3))
	_add_row(col, "gearbox", func(_d): Game.manual_gearbox = not Game.manual_gearbox)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 14)
	col.add_child(bottom)
	var lab := Ui.button("NET LAB (MULTIPLAYER)", Game.GREEN, 28)
	lab.pressed.connect(func(): Game.main.start_netlab())
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(lab)
	var quit := Ui.button("QUIT", Game.PAPER, 28)
	quit.pressed.connect(func(): get_tree().quit())
	bottom.add_child(quit)
	race.grab_focus()

	var card := Ui.panel(Game.PAPER, -16.0, 16.0, true)
	card.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	card.position = Vector2(-520, -170)
	card.rotation = deg_to_rad(2.5)
	_racer_name = Ui.label("", 64, Game.RED, null, 12)
	card.add_child(_racer_name)
	root.add_child(card)

	var hint := Ui.label("ENTER / A to select   LEFT/RIGHT change options", 24, Game.PAPER, Game.FONT_BODY, 6)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(80, -60)
	root.add_child(hint)


func _add_row(col: VBoxContainer, key: String, change: Callable) -> void:
	var b := Ui.button("", Game.CYAN, 28)
	b.pressed.connect(func():
		change.call(1)
		_refresh())
	b.gui_input.connect(func(e: InputEvent):
		if e.is_action_pressed("ui_left"):
			change.call(-1)
			_refresh()
			b.accept_event()
		elif e.is_action_pressed("ui_right"):
			change.call(1)
			_refresh()
			b.accept_event())
	col.add_child(b)
	_rows[key] = b


func _refresh() -> void:
	var racer: Dictionary = Game.ROSTER[Game.player_racer]
	_rows["racer"].text = "<  RACER: %s  >" % racer["name"].to_upper()
	_rows["laps"].text = "<  LAPS: %d  >" % Game.laps
	_rows["rivals"].text = "<  RIVALS: %d  >" % Game.bot_count
	_rows["difficulty"].text = "<  %s  >" % Game.difficulty_name().to_upper()
	_rows["gearbox"].text = "<  GEARBOX: %s  >" % ("MANUAL" if Game.manual_gearbox else "AUTO")
	_racer_name.text = racer["name"].to_upper()
	if _kart_model:
		_kart_model.queue_free()
	_kart_model = Props.make_kart(racer, Game.player_racer)
	_kart_model.scale = Vector3.ONE * 1.25
	_turntable.add_child(_kart_model)
