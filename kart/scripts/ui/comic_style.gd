class_name ComicStyle
extends StyleBox
## Comic panel: skewed flat fill, thick ink border, hard offset shadow,
## optional halftone dot corner.

var fill := Color("ffd21f")
var ink := Color("141018")
var border := 4.0
var skew := 0.0          # pixels the top edge leans right
var shadow := Vector2(7, 7)
var halftone := false
var halftone_color := Color(0, 0, 0, 0.18)


static func make(fill_color: Color, skew_px := 0.0, margin := 14.0, dots := false) -> ComicStyle:
	var s := ComicStyle.new()
	s.fill = fill_color
	s.skew = skew_px
	s.halftone = dots
	s.content_margin_left = margin + absf(skew_px) * 0.5
	s.content_margin_right = margin + absf(skew_px) * 0.5
	s.content_margin_top = margin * 0.6
	s.content_margin_bottom = margin * 0.6
	return s


func _shape(rect: Rect2, off := Vector2.ZERO) -> PackedVector2Array:
	var h := skew * 0.5
	var p := rect.position + off
	var w := rect.size.x
	var hh := rect.size.y
	return PackedVector2Array([p + Vector2(h, 0), p + Vector2(w + h, 0), p + Vector2(w - h, hh), p + Vector2(-h, hh)])


func _draw(ci: RID, rect: Rect2) -> void:
	var rs := RenderingServer
	if shadow != Vector2.ZERO:
		rs.canvas_item_add_polygon(ci, _shape(rect, shadow), PackedColorArray([ink]))
	var pts := _shape(rect)
	rs.canvas_item_add_polygon(ci, pts, PackedColorArray([fill]))
	if halftone:
		var step := 9.0
		var x0 := rect.position.x + rect.size.x * 0.45
		var y := rect.position.y + step * 0.5
		while y < rect.end.y:
			var x := x0
			while x < rect.end.x - absf(skew):
				var t := clampf(((x - x0) / (rect.end.x - x0) + (y - rect.position.y) / rect.size.y) * 0.5, 0.0, 1.0)
				var r := t * step * 0.42
				if r > 0.5:
					rs.canvas_item_add_circle(ci, Vector2(x, y), r, halftone_color)
				x += step
			y += step
	var loop := pts.duplicate()
	loop.append(pts[0])
	loop.append(pts[1])
	rs.canvas_item_add_polyline(ci, loop, PackedColorArray([ink]), border, true)
