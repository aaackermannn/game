class_name Ui
## Small builders for comic UI pieces.


static func label(text: String, size := 32, color := Color.WHITE, font: Font = null, outline := 10) -> Label:
	var l := Label.new()
	l.text = text
	var ls := LabelSettings.new()
	ls.font = font if font else Game.FONT_TITLE
	ls.font_size = size
	ls.font_color = color
	ls.outline_size = outline
	ls.outline_color = Game.INK
	if outline > 0:
		ls.shadow_color = Game.INK
		ls.shadow_offset = Vector2(maxf(outline * 0.35, 2.0), maxf(outline * 0.35, 2.0))
		ls.shadow_size = outline
	l.label_settings = ls
	return l


static func panel(fill: Color, skew := 0.0, margin := 14.0, dots := false) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", ComicStyle.make(fill, skew, margin, dots))
	return p


static func button(text: String, fill := Game.YELLOW, size := 40) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	var normal := ComicStyle.make(fill, 14.0, 22.0)
	var hover := ComicStyle.make(fill.lightened(0.25), 14.0, 22.0)
	hover.shadow = Vector2(10, 10)
	var focus := ComicStyle.make(Game.RED, 14.0, 22.0)
	focus.shadow = Vector2(10, 10)
	var pressed := ComicStyle.make(fill.darkened(0.1), 14.0, 22.0)
	pressed.shadow = Vector2(2, 2)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.set_meta("focus_style", focus)
	b.set_meta("normal_style", normal)
	b.add_theme_font_override("font", Game.FONT_TITLE)
	b.add_theme_font_size_override("font_size", size)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, Game.INK)
	b.focus_entered.connect(func():
		b.add_theme_stylebox_override("normal", focus)
		b.add_theme_stylebox_override("hover", focus)
		b.add_theme_color_override("font_color", Game.PAPER)
		b.add_theme_color_override("font_hover_color", Game.PAPER)
		b.add_theme_color_override("font_focus_color", Game.PAPER)
		Game.sfx("ui_move"))
	b.focus_exited.connect(func():
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_color_override("font_color", Game.INK)
		b.add_theme_color_override("font_hover_color", Game.INK)
		b.add_theme_color_override("font_focus_color", Game.INK))
	b.pressed.connect(func(): Game.sfx("ui_accept"))
	b.mouse_entered.connect(func(): b.grab_focus())
	return b


## Spiky comic starburst polygon (for "GO!" etc.).
static func starburst(center: Vector2, r_out: float, r_in: float, spikes: int, rot := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in spikes * 2:
		var a := rot + TAU * i / (spikes * 2)
		var r := r_out if i % 2 == 0 else r_in
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts
