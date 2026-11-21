class_name Hud
extends CanvasLayer
## Comic race HUD: tilted panels for place/lap/time, item slot + energy,
## standings strip, minimap, speedometer, big flash text, speed lines,
## pause menu and results.

var race: Race

var _place_lbl: Label
var _place_of: Label
var _lap_lbl: Label
var _time_lbl: Label
var _item_icon: ItemIcon
var _item_name: Label
var _energy: EnergyBar
var _standings: VBoxContainer
var _minimap: Minimap
var _speedo: Speedometer
var _flash: FlashText
var _wrong: PanelContainer
var _lines: ColorRect
var _pause: Control
var _results: Control
var _hint: Label
var _line_amt := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 5
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Speed lines (behind panels).
	_lines = ColorRect.new()
	_lines.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sl := ShaderMaterial.new()
	sl.shader = preload("res://shaders/speed_lines.gdshader")
	_lines.material = sl
	root.add_child(_lines)

	# Place panel (top-left).
	var place_panel := Ui.panel(Game.YELLOW, 22.0, 18.0, true)
	place_panel.position = Vector2(28, 22)
	place_panel.rotation = deg_to_rad(-3)
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 2)
	_place_lbl = Ui.label("1ST", 104, Game.RED, null, 16)
	_place_of = Ui.label("/8", 40, Game.INK, null, 0)
	_place_of.size_flags_vertical = Control.SIZE_SHRINK_END
	ph.add_child(_place_lbl)
	ph.add_child(_place_of)
	place_panel.add_child(ph)
	root.add_child(place_panel)

	# Lap + time panel.
	var lap_panel := Ui.panel(Game.RED, 18.0, 14.0)
	lap_panel.position = Vector2(300, 30)
	lap_panel.rotation = deg_to_rad(2)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", -6)
	_lap_lbl = Ui.label("LAP 1/3", 48, Game.YELLOW, null, 10)
	_time_lbl = Ui.label("0:00.00", 32, Game.PAPER, Game.FONT_ITALIC, 8)
	lv.add_child(_lap_lbl)
	lv.add_child(_time_lbl)
	lap_panel.add_child(lv)
	root.add_child(lap_panel)

	# Standings strip (left).
	_standings = VBoxContainer.new()
	_standings.position = Vector2(30, 210)
	_standings.add_theme_constant_override("separation", 4)
	root.add_child(_standings)

	# Item slot + energy (top-right).
	var item_box := VBoxContainer.new()
	item_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	item_box.position = Vector2(-215, 24)
	item_box.add_theme_constant_override("separation", 10)
	var item_panel := Ui.panel(Game.YELLOW, -14.0, 10.0, true)
	item_panel.rotation = deg_to_rad(3)
	_item_icon = ItemIcon.new()
	_item_icon.custom_minimum_size = Vector2(150, 130)
	item_panel.add_child(_item_icon)
	item_box.add_child(item_panel)
	_item_name = Ui.label("", 26, Game.PAPER, null, 8)
	_item_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	item_box.add_child(_item_name)
	_energy = EnergyBar.new()
	_energy.custom_minimum_size = Vector2(186, 34)
	item_box.add_child(_energy)
	root.add_child(item_box)

	# Minimap (bottom-left).
	var map_panel := Ui.panel(Game.YELLOW, 16.0, 10.0)
	map_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	map_panel.position = Vector2(26, -290)
	map_panel.rotation = deg_to_rad(-2)
	_minimap = Minimap.new()
	_minimap.custom_minimum_size = Vector2(300, 240)
	_minimap.race = race
	map_panel.add_child(_minimap)
	root.add_child(map_panel)

	# Speedometer (bottom-right).
	var sp_panel := Ui.panel(Game.YELLOW, -16.0, 10.0, true)
	sp_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	sp_panel.position = Vector2(-300, -230)
	sp_panel.rotation = deg_to_rad(2)
	_speedo = Speedometer.new()
	_speedo.custom_minimum_size = Vector2(250, 180)
	sp_panel.add_child(_speedo)
	root.add_child(sp_panel)

	# Wrong way.
	_wrong = Ui.panel(Game.RED, 20.0, 20.0)
	_wrong.add_child(Ui.label("WRONG WAY!", 64, Game.YELLOW, null, 14))
	_wrong.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_wrong.position = Vector2(-190, 170)
	_wrong.visible = false
	root.add_child(_wrong)

	# Controls hint (fades after start).
	_hint = Ui.label("W/S drive   A/D steer   SPACE drift   E item   R energy burst   C look back   ESC pause", 24, Game.PAPER, Game.FONT_BODY, 6)
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(-430, -50)
	root.add_child(_hint)

	_flash = FlashText.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_flash)

	_build_pause(root)
	_results = Control.new()
	_results.set_anchors_preset(Control.PRESET_FULL_RECT)
	_results.visible = false
	root.add_child(_results)


func flash_big(text: String, color: Color, hold := 0.8) -> void:
	_flash.show_text(text, color, hold)


func results_visible() -> bool:
	return _results.visible


func _process(_delta: float) -> void:
	if race == null or race.player == null:
		return
	var p := race.player
	_minimap.race = race
	_place_lbl.text = Game.ordinal(p.place)
	_place_of.text = "/%d" % race.karts.size()
	_lap_lbl.text = "LAP %d/%d" % [clampi(p.lap, 1, Game.laps), Game.laps]
	_time_lbl.text = Game.format_time(race.race_time)
	_item_icon.item = p.item
	_item_icon.rolling = p.roulette_time > 0.0
	_item_name.text = "" if _item_icon.rolling else Items.LABELS.get(p.item, "")
	if p.item == "turbo3" and not _item_icon.rolling:
		_item_name.text = "TURBO x%d" % p.item_count
	_energy.value = p.energy
	_speedo.speed = absf(p.speed)
	_speedo.max_speed = p.max_speed
	_speedo.drift_level = p.drift_level
	_wrong.visible = p.wrong_way_time > 0.8 and int(Time.get_ticks_msec() / 300) % 2 == 0
	var boost := 1.0 if p.is_boosting() else clampf((p.speed / p.max_speed - 0.85) * 2.0, 0.0, 0.4)
	_line_amt = lerpf(_line_amt, boost, 0.15)
	(_lines.material as ShaderMaterial).set_shader_parameter("intensity", _line_amt)
	if race.race_time > 8.0:
		_hint.modulate.a = maxf(_hint.modulate.a - _delta, 0.0)
	_update_standings()
	if Input.is_action_just_pressed("pause") and not _results.visible and race.phase != Race.Phase.INTRO:
		_toggle_pause()
	if Input.is_action_just_pressed("restart_race"):
		get_tree().paused = false
		Game.main.start_race()


func _update_standings() -> void:
	var order := race.ordered_karts()
	while _standings.get_child_count() < order.size():
		var row := Ui.panel(Game.PAPER, 10.0, 6.0)
		(row.get_theme_stylebox("panel") as ComicStyle).shadow = Vector2(4, 4)
		(row.get_theme_stylebox("panel") as ComicStyle).border = 3.0
		var h := HBoxContainer.new()
		var num := Ui.label("1", 24, Game.INK, null, 0)
		num.custom_minimum_size.x = 26
		var chip := ColorRect.new()
		chip.custom_minimum_size = Vector2(14, 14)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var nm := Ui.label("", 22, Game.INK, Game.FONT_BODY, 0)
		nm.custom_minimum_size.x = 110
		h.add_child(num)
		h.add_child(chip)
		h.add_child(nm)
		row.add_child(h)
		_standings.add_child(row)
	for i in order.size():
		var k: Kart = order[i]
		var row := _standings.get_child(i) as PanelContainer
		var h := row.get_child(0)
		(h.get_child(0) as Label).text = str(i + 1)
		(h.get_child(1) as ColorRect).color = k.racer["body"]
		(h.get_child(2) as Label).text = k.display_name.to_upper()
		var st := row.get_theme_stylebox("panel") as ComicStyle
		var want := Game.YELLOW if k.is_player else Game.PAPER
		if st.fill != want:
			st.fill = want
			row.queue_redraw()
		row.position.x = 18.0 if k.is_player else 0.0


# --- Pause -----------------------------------------------------------------------

func _build_pause(root: Control) -> void:
	_pause = Control.new()
	_pause.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.06, 0.1, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.add_child(dim)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-170, -200)
	box.custom_minimum_size = Vector2(340, 0)
	box.add_theme_constant_override("separation", 18)
	var title := Ui.label("PAUSED", 96, Game.YELLOW, null, 18)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.rotation = deg_to_rad(-4)
	box.add_child(title)
	var resume := Ui.button("RESUME")
	resume.pressed.connect(_toggle_pause)
	var restart := Ui.button("RESTART", Game.CYAN)
	restart.pressed.connect(func():
		get_tree().paused = false
		Game.main.start_race())
	var quit := Ui.button("MAIN MENU", Game.PAPER)
	quit.pressed.connect(func():
		get_tree().paused = false
		Game.main.show_menu())
	for b in [resume, restart, quit]:
		box.add_child(b)
	_pause.add_child(box)
	root.add_child(_pause)


func _toggle_pause() -> void:
	var p := not get_tree().paused
	get_tree().paused = p
	_pause.visible = p
	if p:
		(_pause.get_child(1).get_child(1) as Button).grab_focus()
		Game.sfx("ui_back")


# --- Results ---------------------------------------------------------------------

func show_results() -> void:
	_results.visible = true
	for c in _results.get_children():
		c.queue_free()
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.06, 0.1, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_results.add_child(dim)
	var panel := Ui.panel(Game.PAPER, 18.0, 28.0, true)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-380, -330)
	panel.custom_minimum_size = Vector2(760, 0)
	panel.rotation = deg_to_rad(-1.5)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	var player_place := 0
	for i in Game.last_results.size():
		if Game.last_results[i]["is_player"]:
			player_place = i + 1
	var head := Ui.label("YOU FINISHED %s!" % Game.ordinal(player_place) if player_place > 0 else "RESULTS", 64, Game.RED, null, 14)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(head)
	for i in Game.last_results.size():
		var r: Dictionary = Game.last_results[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var col := Game.RED if r["is_player"] else Game.INK
		var a := Ui.label(Game.ordinal(i + 1), 34, col, null, 0)
		a.custom_minimum_size.x = 80
		var chip := ColorRect.new()
		chip.color = r["color"]
		chip.custom_minimum_size = Vector2(22, 22)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var b := Ui.label(r["name"].to_upper() + ("  (YOU)" if r["is_player"] else ""), 34, col, Game.FONT_BODY, 0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var c := Ui.label(Game.format_time(r["time"]), 34, col, Game.FONT_ITALIC, 0)
		var d := Ui.label("best " + Game.format_time(r["best"]), 24, Color(Game.INK, 0.6), Game.FONT_BODY, 0)
		d.custom_minimum_size.x = 120
		for x in [a, chip, b, c, d]:
			row.add_child(x)
		v.add_child(row)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 30)
	var again := Ui.button("RACE AGAIN")
	again.pressed.connect(func(): Game.main.start_race())
	var menu := Ui.button("MAIN MENU", Game.CYAN)
	menu.pressed.connect(func(): Game.main.show_menu())
	btns.add_child(again)
	btns.add_child(menu)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 16
	v.add_child(spacer)
	v.add_child(btns)
	panel.add_child(v)
	_results.add_child(panel)
	again.grab_focus()


# --- Widgets ---------------------------------------------------------------------

class ItemIcon:
	extends Control
	var item := ""
	var rolling := false

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var it := item
		if rolling:
			it = Items.ALL[int(Time.get_ticks_msec() / 90) % Items.ALL.size()]
		if it == "":
			draw_circle(c, 26, Color(Game.INK, 0.15))
			return
		var s := minf(size.x, size.y) / 130.0
		draw_set_transform(c, -0.25 if it == "rocket" else 0.0, Vector2(s, s))
		match it:
			"rocket":
				_poly([Vector2(-14, -40), Vector2(14, -40), Vector2(14, 30), Vector2(-14, 30)], Game.RED)
				_poly([Vector2(-14, -40), Vector2(0, -62), Vector2(14, -40)], Game.PAPER)
				_poly([Vector2(-14, 10), Vector2(-30, 38), Vector2(-14, 30)], Game.YELLOW)
				_poly([Vector2(14, 10), Vector2(30, 38), Vector2(14, 30)], Game.YELLOW)
				_poly([Vector2(-10, 30), Vector2(0, 58), Vector2(10, 30)], Game.ORANGE)
				draw_circle(Vector2(0, -16), 7, Game.CYAN)
			"mine":
				_poly(Ui.starburst(Vector2(0, 14), 46, 30, 9, 0.3), Game.INK)
				draw_circle(Vector2(0, 0), 26, Game.PURPLE)
				draw_circle(Vector2(-9, -9), 7, Color(1, 1, 1, 0.55))
				draw_line(Vector2(8, -22), Vector2(18, -40), Game.INK, 5)
			"turbo", "turbo3":
				var n := 3 if it == "turbo3" else 1
				for i in n:
					var o := Vector2((i - (n - 1) * 0.5) * 26.0, 0.0)
					var sc := 1.0 if n == 1 else 0.62
					_poly([o + Vector2(-34, 30) * sc, o + Vector2(-6, -44) * sc, o + Vector2(2, -6) * sc, o + Vector2(30, -12) * sc, o + Vector2(4, 50) * sc, o + Vector2(-4, 14) * sc], Game.ORANGE)
			"bouncer":
				draw_circle(Vector2.ZERO, 40, Game.INK)
				draw_circle(Vector2.ZERO, 35, Game.CYAN)
				draw_rect(Rect2(-35, -7, 70, 14), Game.YELLOW)
				draw_circle(Vector2(-13, -15), 8, Color(1, 1, 1, 0.75))
				draw_arc(Vector2.ZERO, 40, 0, TAU, 40, Game.INK, 5.0)
			"rampage":
				_poly(Ui.starburst(Vector2.ZERO, 50, 26, 8, -PI / 2), Game.YELLOW)
				draw_circle(Vector2(-8, -6), 5, Game.INK)
				draw_circle(Vector2(8, -6), 5, Game.INK)
				draw_line(Vector2(-10, 10), Vector2(10, 10), Game.INK, 4)
			"zap":
				_poly([Vector2(6, -58), Vector2(-26, 6), Vector2(-2, 6), Vector2(-12, 58), Vector2(28, -10), Vector2(4, -10)], Game.YELLOW)
			"kaboom":
				draw_circle(Vector2(0, 8), 38, Game.INK)
				draw_circle(Vector2(0, 8), 33, Game.RED)
				draw_circle(Vector2(-12, -4), 8, Color(1, 1, 1, 0.5))
				draw_line(Vector2(14, -22), Vector2(26, -44), Game.INK, 6)
				_poly(Ui.starburst(Vector2(28, -48), 14, 6, 6), Game.YELLOW)
		draw_set_transform(Vector2.ZERO)

	func _poly(pts: Array, col: Color) -> void:
		var p := PackedVector2Array(pts)
		draw_colored_polygon(p, col)
		p.append(p[0])
		draw_polyline(p, Game.INK, 4.0, true)


class EnergyBar:
	extends Control
	var value := 0.0

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var w := (size.x - 16.0) / 3.0
		for i in 3:
			var x := i * (w + 8.0)
			var fill := clampf((value - i * 33.3) / 33.3, 0.0, 1.0)
			var r := Rect2(x, 0, w, size.y)
			draw_rect(Rect2(r.position + Vector2(4, 4), r.size), Game.INK)
			draw_rect(r, Color(Game.INK, 0.5))
			draw_rect(Rect2(r.position, Vector2(w * fill, size.y)), Game.CYAN if fill >= 1.0 else Game.BLUE)
			draw_rect(r, Game.INK, false, 3.0)
		if value >= 33.0 and int(Time.get_ticks_msec() / 250) % 2 == 0:
			draw_string(Game.FONT_TITLE, Vector2(4, size.y - 8), "R: BURST", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Game.PAPER)


class Minimap:
	extends Control
	var race: Race
	var _pts := PackedVector2Array()
	var _xf := Transform2D.IDENTITY

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if race == null or race.track == null:
			return
		if _pts.is_empty():
			var pts := race.track.minimap_points
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for p in pts:
				lo = lo.min(p)
				hi = hi.max(p)
			var s := minf((size.x - 30.0) / (hi.x - lo.x), (size.y - 30.0) / (hi.y - lo.y))
			var off := (size - (hi - lo) * s) * 0.5
			_xf = Transform2D(0.0, Vector2(s, s), 0.0, off - lo * s)
			for p in pts:
				_pts.append(_xf * p)
			_pts.append(_pts[0])
		draw_polyline(_pts, Game.INK, 16.0, true)
		draw_polyline(_pts, Game.PAPER, 9.0, true)
		var sp := _pts[0]
		draw_line(sp + Vector2(0, -9), sp + Vector2(0, 9), Game.RED, 4.0)
		var order := race.ordered_karts()
		order.reverse()
		for k in order:
			var p := _xf * Vector2(k.global_position.x, k.global_position.z)
			var r := 9.0 if k.is_player else 6.5
			draw_circle(p, r + 3.0, Game.INK)
			draw_circle(p, r, k.racer["body"])
			if k.is_player:
				draw_arc(p, r + 7.0, 0, TAU, 20, Game.RED, 3.0)


class Speedometer:
	extends Control
	var speed := 0.0
	var max_speed := 30.0
	var drift_level := 0
	var _shown := 0.0

	func _process(delta: float) -> void:
		_shown = lerpf(_shown, speed, clampf(delta * 10.0, 0.0, 1.0))
		queue_redraw()

	func _draw() -> void:
		var c := Vector2(size.x * 0.5, size.y * 0.86)
		var r := minf(size.x * 0.46, size.y * 0.8)
		draw_circle(c, r + 6.0, Game.INK)
		draw_circle(c, r, Game.PAPER)
		# Red zone + ticks.
		var a0 := PI
		var a1 := TAU
		draw_arc(c, r - 10.0, lerpf(a0, a1, 0.78), a1, 16, Game.RED, 14.0)
		for i in 11:
			var a := lerpf(a0, a1, i / 10.0)
			var d := Vector2(cos(a), sin(a))
			draw_line(c + d * (r - 4.0), c + d * (r - (22.0 if i % 2 == 0 else 13.0)), Game.INK, 4.0 if i % 2 == 0 else 2.5)
		var kmh := _shown * 3.6
		var t := clampf(_shown / (max_speed * 1.45), 0.0, 1.0)
		var na := lerpf(a0, a1, t)
		var nd := Vector2(cos(na), sin(na))
		var needle_col: Color = Kart.DRIFT_COLORS[drift_level] if drift_level > 0 else Game.RED
		draw_line(c, c + nd * (r - 18.0), Game.INK, 10.0)
		draw_line(c, c + nd * (r - 20.0), needle_col, 5.0)
		draw_circle(c, 12.0, Game.INK)
		draw_string_outline(Game.FONT_TITLE, Vector2(c.x - 70, c.y - 34), "%d" % kmh, HORIZONTAL_ALIGNMENT_CENTER, 140, 56, 10, Game.INK)
		draw_string(Game.FONT_TITLE, Vector2(c.x - 70, c.y - 34), "%d" % kmh, HORIZONTAL_ALIGNMENT_CENTER, 140, 56, Game.YELLOW)
		draw_string(Game.FONT_TITLE, Vector2(c.x - 70, c.y - 8), "KM/H", HORIZONTAL_ALIGNMENT_CENTER, 140, 22, Game.INK)


class FlashText:
	extends Control
	var _text := ""
	var _color := Color.WHITE
	var _t := 0.0
	var _hold := 0.8

	func show_text(text: String, color: Color, hold := 0.8) -> void:
		_text = text
		_color = color
		_hold = hold
		_t = 0.0

	func _process(delta: float) -> void:
		if _text == "":
			return
		_t += delta
		if _t > _hold + 0.35:
			_text = ""
		queue_redraw()

	func _draw() -> void:
		if _text == "":
			return
		var pop := 1.0 - pow(1.0 - clampf(_t / 0.18, 0.0, 1.0), 3.0)
		var fade := 1.0 - clampf((_t - _hold) / 0.35, 0.0, 1.0)
		var c := Vector2(size.x * 0.5, size.y * 0.38)
		var font_size := 170 if _text.length() <= 4 else 120
		var scale := 0.4 + 0.6 * pop + (1.0 - fade) * 0.3
		draw_set_transform(c, -0.06, Vector2(scale, scale))
		var a := Color(1, 1, 1, fade)
		var w := Game.FONT_TITLE.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var r := w * 0.5 + 90.0
		draw_colored_polygon(Ui.starburst(Vector2(8, 10), r, r * 0.72, 18, _t * 0.4), Game.INK * a)
		draw_colored_polygon(Ui.starburst(Vector2.ZERO, r, r * 0.72, 18, _t * 0.4), Color(Game.PAPER, fade))
		draw_colored_polygon(Ui.starburst(Vector2.ZERO, r * 0.82, r * 0.6, 18, _t * 0.4 + 0.1), Color(_color.lightened(0.5), fade))
		var pos := Vector2(-w * 0.5, font_size * 0.35)
		draw_string_outline(Game.FONT_TITLE, pos + Vector2(6, 6), _text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 24, Color(Game.INK, fade))
		draw_string_outline(Game.FONT_TITLE, pos, _text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 24, Color(Game.INK, fade))
		draw_string(Game.FONT_TITLE, pos, _text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(_color, fade))
		draw_set_transform(Vector2.ZERO)
