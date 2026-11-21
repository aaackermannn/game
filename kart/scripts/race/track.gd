class_name Track
extends Node3D
## "Sunny Cove" — island circuit built procedurally from a closed spline:
## road, kerbs, barriers, island, sea, props, item boxes and energy orbs.
## Also answers spatial questions for racing (progress along track, lateral offset).

const CONTROL_POINTS := [
	Vector2(0, 0), Vector2(70, 0), Vector2(120, -6), Vector2(148, -32), Vector2(150, -72),
	Vector2(126, -98), Vector2(88, -96), Vector2(64, -70), Vector2(34, -62), Vector2(4, -86),
	Vector2(-36, -112), Vector2(-84, -108), Vector2(-114, -78), Vector2(-112, -36),
	Vector2(-122, 8), Vector2(-118, 50), Vector2(-94, 84), Vector2(-54, 96), Vector2(-22, 80),
	Vector2(-20, 50), Vector2(-42, 28), Vector2(-46, 6), Vector2(-26, -2),
]
const SCALE := 1.25
const HALF_WIDTH := 8.0
const KERB_WIDTH := 1.6
const BARRIER_GAP := 5.0          # grass run-off between kerb and barrier
const STEP := 2.0

var curve := Curve3D.new()
var length := 0.0
var center := Vector3.ZERO
var island_radius := 0.0
var minimap_points := PackedVector2Array()
var item_box_spots: Array[Vector3] = []
var energy_spots: Array[Vector3] = []

var _rng := RandomNumberGenerator.new()


func build() -> void:
	_rng.seed = 7
	_build_curve()
	_build_road()
	_build_island()
	_build_barriers()
	_build_props()
	_plan_pickups()


# --- Queries -------------------------------------------------------------------

func wrap_offset(o: float) -> float:
	return fposmod(o, length)


func point_at(o: float) -> Vector3:
	return curve.sample_baked(wrap_offset(o), true)


func forward_at(o: float) -> Vector3:
	var a := point_at(o - 1.0)
	var b := point_at(o + 1.0)
	var f := b - a
	f.y = 0.0
	return f.normalized()


func right_at(o: float) -> Vector3:
	return forward_at(o).cross(Vector3.UP).normalized()


## Road half-width (centre to kerb) at offset `o`.
func half_width_at(_o: float) -> float:
	return HALF_WIDTH


func kerb_width() -> float:
	return KERB_WIDTH


## True when a kart has left the playable area (sea, off the map) and must respawn.
func is_out_of_bounds(pos: Vector3, _o: float) -> bool:
	var from_center := Vector2(pos.x - center.x, pos.z - center.z).length()
	return from_center > island_radius + 6.0 or pos.y < -4.0


func closest_offset(pos: Vector3) -> float:
	return curve.get_closest_offset(Vector3(pos.x, 0.0, pos.z))


## Signed distance from the centre line (+ = right of travel direction).
func lateral(pos: Vector3, o: float) -> float:
	var d := pos - point_at(o)
	d.y = 0.0
	return d.dot(right_at(o))


func transform_at(o: float, lat := 0.0) -> Transform3D:
	var f := forward_at(o)
	var p := point_at(o) + right_at(o) * lat
	var t := Transform3D(Basis.looking_at(f, Vector3.UP), p)
	return t


## Grid slot transform for starting position `i` (0 = pole).
func grid_transform(i: int) -> Transform3D:
	var row := i / 2
	var side := -1.0 if i % 2 == 0 else 1.0
	var o := length - 7.0 - row * 7.0 - (3.5 if side > 0 else 0.0)
	var t := transform_at(o, side * HALF_WIDTH * 0.45)
	t.origin.y = 0.6
	return t


# --- Build ---------------------------------------------------------------------

func _build_curve() -> void:
	var pts: Array[Vector3] = []
	for p in CONTROL_POINTS:
		pts.append(Vector3(p.x, 0, p.y) * SCALE)
	var n := pts.size()
	# Catmull-Rom → Bezier handles; first point repeated to close the loop.
	for i in n + 1:
		var p: Vector3 = pts[i % n]
		var tangent: Vector3 = (pts[(i + 1) % n] - pts[(i - 1 + n) % n]) / 6.0
		curve.add_point(p, -tangent, tangent)
	curve.bake_interval = 0.5
	length = curve.get_baked_length()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var o := 0.0
	while o < length:
		var p := point_at(o)
		minimap_points.append(Vector2(p.x, p.z))
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
		o += 4.0
	center = Vector3((lo.x + hi.x) * 0.5, 0, (lo.y + hi.y) * 0.5)
	for p in minimap_points:
		island_radius = maxf(island_radius, Vector2(center.x, center.z).distance_to(p))
	island_radius += 42.0


func _strip(lat_a: float, lat_b: float, y: float, u_a := 0.0, u_b := 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := int(ceil(length / STEP))
	for i in steps:
		var o0 := i * length / steps
		var o1 := (i + 1) * length / steps
		var r0 := right_at(o0)
		var r1 := right_at(o1)
		var c0 := point_at(o0)
		var c1 := point_at(o1)
		var a0 := c0 + r0 * lat_a + Vector3.UP * y
		var b0 := c0 + r0 * lat_b + Vector3.UP * y
		var a1 := c1 + r1 * lat_a + Vector3.UP * y
		var b1 := c1 + r1 * lat_b + Vector3.UP * y
		# v runs along the track in metres (offset), so stripes stay even.
		var v1 := o1 if i < steps - 1 else length
		for q in [[a0, u_a, o0], [a1, u_a, v1], [b1, u_b, v1], [a0, u_a, o0], [b1, u_b, v1], [b0, u_b, o0]]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(q[1], q[2]))
			st.add_vertex(q[0])
	return st.commit()


func _add_mesh(mesh: Mesh, material: Material, node_name: String, shadows := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _build_road() -> void:
	var road_mat := Toon.surface(0, Color("4a4858"), Color("fff6dc"), 3.0, length)
	_add_mesh(_strip(-HALF_WIDTH, HALF_WIDTH, 0.03), road_mat, "Road")
	var kerb_mat := Toon.surface(1, Color("ec2b3a"), Color("fff6dc"), 2.5, length)
	_add_mesh(_strip(-HALF_WIDTH - KERB_WIDTH, -HALF_WIDTH, 0.045), kerb_mat, "KerbL")
	_add_mesh(_strip(HALF_WIDTH, HALF_WIDTH + KERB_WIDTH, 0.045), kerb_mat, "KerbR")


func _build_island() -> void:
	var c2 := Vector2(center.x, center.z)
	# Grass disc.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 96
	var sand := 16.0
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var wob0 := _shore_wobble(a0)
		var wob1 := _shore_wobble(a1)
		var p0 := Vector3(cos(a0), 0, sin(a0)) * (island_radius + wob0)
		var p1 := Vector3(cos(a1), 0, sin(a1)) * (island_radius + wob1)
		for v in [Vector3.ZERO, p0, p1]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v.x, v.z) / 6.0)
			st.add_vertex(center + v)
	_add_mesh(st.commit(), Toon.surface(2, Color("6bcf4a")), "Grass")
	# Sand ring sloping into the sea.
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var r0 := island_radius + _shore_wobble(a0)
		var r1 := island_radius + _shore_wobble(a1)
		var i0 := center + d0 * r0 + Vector3.UP * 0.0
		var i1 := center + d1 * r1
		var o0 := center + d0 * (r0 + sand) + Vector3.DOWN * 1.6
		var o1 := center + d1 * (r1 + sand) + Vector3.DOWN * 1.6
		for v in [i0, o1, i1, i0, o0, o1]:
			st.set_uv(Vector2(v.x, v.z) / 4.0)
			st.add_vertex(v)
	st.generate_normals()
	_add_mesh(st.commit(), Toon.surface(3, Color("ffe08a")), "Beach")
	# Sea.
	var sea := PlaneMesh.new()
	sea.size = Vector2(3000, 3000)
	var sea_mat := ShaderMaterial.new()
	sea_mat.shader = preload("res://shaders/water.gdshader")
	sea_mat.set_shader_parameter("center", c2)
	sea_mat.set_shader_parameter("shore_radius", island_radius + sand * 0.6)
	var sea_mi := _add_mesh(sea, sea_mat, "Sea")
	sea_mi.position = center + Vector3.DOWN * 0.9
	# Ground collision (flat island; the sea is handled by respawn logic).
	var body := StaticBody3D.new()
	body.name = "Ground"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	body.add_child(cs)
	add_child(body)


func _shore_wobble(a: float) -> float:
	return sin(a * 3.0 + 1.0) * 7.0 + sin(a * 7.0) * 3.0


func _build_barriers() -> void:
	var dist := HALF_WIDTH + KERB_WIDTH + BARRIER_GAP
	var body := StaticBody3D.new()
	body.name = "Barriers"
	add_child(body)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := 1.1
	var w := 0.9
	var step := 3.0
	var n := int(length / step)
	for side: float in [-1.0, 1.0]:
		var prev := Vector3.INF
		for i in n + 1:
			var o := i * length / n
			var p := point_at(o) + right_at(o) * dist * side
			var ok := absf(curve.get_closest_point(p).distance_to(p) - dist) < 0.8
			if ok and prev != Vector3.INF and prev.distance_to(p) < step * 2.0 and prev.distance_to(p) > 0.3:
				_barrier_segment(st, body, prev, p, h, w, o)
			prev = p if ok else Vector3.INF
	st.generate_normals()
	_add_mesh(st.commit(), Toon.surface(4, Color("ffd21f"), Color("ec2b3a"), 6.0), "BarrierMesh", true)


func _barrier_segment(st: SurfaceTool, body: StaticBody3D, a: Vector3, b: Vector3, h: float, w: float, o: float) -> void:
	var f := (b - a)
	var len := f.length()
	f = f / len
	var r := f.cross(Vector3.UP) * w * 0.5
	var up := Vector3.UP * h
	var c := [a - r, a + r, b + r, b - r]
	var v0 := o - len
	var v1 := o
	# top + two sides (+ end caps are hidden by neighbours)
	var quads := [
		[c[0] + up, c[3] + up, c[2] + up, c[1] + up],
		[c[0], c[3], c[3] + up, c[0] + up],
		[c[1], c[1] + up, c[2] + up, c[2]],
	]
	for q in quads:
		var uvs := [Vector2(0, v0), Vector2(0, v1), Vector2(1, v1), Vector2(1, v0)]
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uvs[idx])
			st.add_vertex(q[idx])
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(w, h * 2.0, len + 0.3)
	cs.shape = box
	cs.transform = Transform3D(Basis.looking_at(f, Vector3.UP), (a + b) * 0.5 + Vector3.UP * h * 0.5)
	body.add_child(cs)


func _free_spot(p: Vector3, min_track_dist: float) -> bool:
	return curve.get_closest_point(Vector3(p.x, 0, p.z)).distance_to(Vector3(p.x, 0, p.z)) > min_track_dist


func _place(model: String, pos: Vector3, yaw: float, scale_mul := 1.0, collide_radius := 0.0) -> Node3D:
	var node := Props.make(model)
	node.position = pos
	node.rotation.y = yaw
	node.scale *= scale_mul
	add_child(node)
	if collide_radius > 0.0:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = collide_radius * scale_mul
		cyl.height = 4.0
		cs.shape = cyl
		cs.position.y = 2.0
		body.add_child(cs)
		node.add_child(body)
	return node


func _build_props() -> void:
	var edge := HALF_WIDTH + KERB_WIDTH + BARRIER_GAP
	# Start/finish gantry.
	var g := transform_at(0.0)
	var gantry := _place("gantry", g.origin, 0.0)
	gantry.basis = g.basis
	# Grandstands along the main straight, outside the barrier.
	for o in [22.0, 48.0]:
		var t := transform_at(o, -(edge + 9.0))
		var gs := _place("grandstand", t.origin, 0.0)
		gs.look_at(point_at(o), Vector3.UP)  # model front (-Z) faces the track
	# Lighthouse on the far shore.
	var lh_dir := Vector3(-0.55, 0, -0.83).normalized()
	_place("lighthouse", center + lh_dir * (island_radius - 6.0), 0.3, 1.0, 3.0)
	# Palms scattered on the island.
	var placed: Array[Vector3] = []
	var tries := 0
	while placed.size() < 80 and tries < 3000:
		tries += 1
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * (island_radius - 6.0)
		var p := center + Vector3(cos(a), 0, sin(a)) * r
		if not _free_spot(p, edge + 4.0):
			continue
		var crowded := false
		for q in placed:
			if q.distance_to(p) < 9.0:
				crowded = true
				break
		if crowded:
			continue
		placed.append(p)
		_place("palm", p, _rng.randf() * TAU, _rng.randf_range(0.85, 1.25), 0.5)
	# Bushes and rocks.
	for i in 60:
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(0.2, 1.0) * (island_radius - 4.0)
		var p := center + Vector3(cos(a), 0, sin(a)) * r
		if _free_spot(p, edge + 3.0):
			_place("bush", p, _rng.randf() * TAU, _rng.randf_range(0.8, 1.5))
	for i in 34:
		var a := _rng.randf() * TAU
		var r := island_radius + _shore_wobble(a) + _rng.randf_range(2.0, 14.0)
		var p := center + Vector3(cos(a), -0.6, sin(a)) * 1.0
		p = center + Vector3(cos(a) * r, -0.7, sin(a) * r)
		_place("rock", p, _rng.randf() * TAU, _rng.randf_range(0.8, 2.4))
	# Tire stacks on the outside of corners.
	var o := 0.0
	while o < length:
		var f0 := forward_at(o - 6.0)
		var f1 := forward_at(o + 6.0)
		var turn := f0.signed_angle_to(f1, Vector3.UP)
		if absf(turn) > 0.35:
			var side := 1.0 if turn > 0.0 else -1.0  # outside of the bend
			var p := point_at(o) + right_at(o) * side * (edge + 2.2)
			if _free_spot(p, edge + 1.0):
				_place("tires", p, _rng.randf() * TAU, 1.0, 0.9)
			o += 10.0
		o += 4.0


func _plan_pickups() -> void:
	for frac in [0.16, 0.44, 0.7]:
		var o: float = length * frac
		for k in 4:
			var lat := lerpf(-HALF_WIDTH * 0.62, HALF_WIDTH * 0.62, k / 3.0)
			item_box_spots.append(transform_at(o, lat).origin + Vector3.UP * 1.1)
	for frac in [0.05, 0.27, 0.36, 0.55, 0.62, 0.85, 0.93]:
		var o: float = length * frac
		var phase := _rng.randf() * TAU
		for k in 6:
			var lat := sin(phase + k * 0.6) * HALF_WIDTH * 0.55
			energy_spots.append(transform_at(o + k * 4.0, lat).origin + Vector3.UP * 0.9)
