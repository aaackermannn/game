class_name SunsetTrack
extends Track
## Sunset Bay Circuit, ported from kart-royale (MIT, github.com/ryancampbell/kart-royale).
## Geometry comes from assets/world/*.glb (exported by tools/kart_royale_export) and the
## centreline (2 m stations: position, frame, width, banking, walls) from track_data.json.

const DATA_PATH := "res://assets/world/track_data.json"
const TRACK_GLB := "res://assets/world/track.glb"
const SCENERY_GLB := "res://assets/world/scenery.glb"
## Track meshes karts drive on (trimesh collision).
## (Markings and boost pads are thin decals on the road: no collision, or karts bump over their edges.)
const DRIVABLE := ["road", "kerbs", "shoulders", "terrain", "bridge"]
## Track meshes karts bump into.
const SOLID := ["guardrail", "tunnel-bore"]
const WALL_HEIGHT := [0.0, 0.92, 4.5, 1.15]  # none, guardrail, rock, parapet

var sea_y := 0.0
var _half := PackedFloat32Array()
var _station_spacing := 2.0
var _grid: Array = []
var _stations: Array = []
var _f: Dictionary = {}  # field name -> column index

## Station columns as packed arrays (hot path for probes and wall collision).
var S := {}
var station_count := 0
var _boost_pads: Array = []
var _corner_table := PackedFloat32Array()
var _ray := PhysicsRayQueryParameters3D.new()

enum Surface { ROAD, DIRT, GRASS, SAND, BOOST, OFF_TRACK, WATER }
## kart-royale SURFACE_PROPS: grip, drag, max speed, rumble.
const SURFACE_PROPS := [
	[1.0, 1.0, 1.0, 0.0],      # road
	[0.78, 1.5, 0.82, 0.035],  # dirt
	[0.70, 2.1, 0.68, 0.028],  # grass
	[0.62, 2.6, 0.60, 0.045],  # sand
	[1.0, 0.6, 1.35, 0.0],     # boost
	[0.55, 3.2, 0.5, 0.05],    # off-track
	[0.45, 4.0, 0.35, 0.02],   # water
]
const KERB_W := 1.6


func build() -> void:
	_rng.seed = 11
	_load_data()
	_build_geometry()
	_build_sea()
	_build_corner_table()
	_plan_pickups()


# --- Queries (overrides) ---------------------------------------------------------

func half_width_at(o: float) -> float:
	if _half.is_empty():
		return HALF_WIDTH
	var n := _half.size()
	var x := wrap_offset(o) / length * n
	var i := int(x) % n
	return lerpf(_half[i], _half[(i + 1) % n], x - floorf(x))


func kerb_width() -> float:
	return 1.6


## Lateral offsets follow the banked road surface (kart-royale's binormal).
func transform_at(o: float, lat := 0.0) -> Transform3D:
	var f := forward_at(o)
	var b := _banked_right(o)
	return Transform3D(Basis.looking_at(f, Vector3.UP), point_at(o) + b * lat)


func _banked_right(o: float) -> Vector3:
	if _stations.is_empty():
		return right_at(o)
	var n := _stations.size()
	var x := wrap_offset(o) / length * n
	var a: Array = _stations[int(x) % n]
	var c: Array = _stations[(int(x) + 1) % n]
	var t := x - floorf(x)
	var b := Vector3(lerpf(a[_f["bx"]], c[_f["bx"]], t), lerpf(a[_f["by"]], c[_f["by"]], t), lerpf(a[_f["bz"]], c[_f["bz"]], t))
	return b.normalized()


func closest_offset(pos: Vector3) -> float:
	# The circuit climbs and dips; match in 3D, not on a flattened plane.
	return curve.get_closest_offset(pos)


func is_out_of_bounds(pos: Vector3, o: float) -> bool:
	if pos.y < sea_y - 1.5:
		return true
	return absf(lateral(pos, o)) > half_width_at(o) + 60.0


func grid_transform(i: int) -> Transform3D:
	if i >= _grid.size():
		return super.grid_transform(i)
	var g: Dictionary = _grid[i]
	var p := Vector3(g["pos"][0], g["pos"][1], g["pos"][2])
	var f := forward_at(closest_offset(p))
	return Transform3D(Basis.looking_at(f, Vector3.UP), p + Vector3.UP * 0.8)


# --- kart-royale track API (ground probe, walls, sampling) ---------------------------

## Station index nearest to `p`, searching around `hint` (a station index) first.
func find_station(p: Vector3, hint: int) -> int:
	var n := station_count
	var px: PackedFloat32Array = S["px"]
	var pz: PackedFloat32Array = S["pz"]
	var best := hint
	var best_d := INF
	for k in range(-12, 13):
		var i := posmod(hint + k, n)
		var d := Vector2(p.x - px[i], p.z - pz[i]).length_squared()
		if d < best_d:
			best_d = d
			best = i
	if best_d > 900.0:  # far from the hint: full scan
		for i in n:
			var d := Vector2(p.x - px[i], p.z - pz[i]).length_squared()
			if d < best_d:
				best_d = d
				best = i
	return best


## kart-royale Track.probe: ground height + normal under `p`, surface type, lateral
## offset, lap fraction `t` and edge ratio. Height and normal come from the drivable
## collision meshes; the surface classification from the layout tables.
func probe(p: Vector3, hint_t: float) -> Dictionary:
	var n := station_count
	var i := find_station(p, int(fposmod(hint_t, 1.0) * n) % n)
	var d := p - Vector3(S["px"][i], S["py"][i], S["pz"][i])
	var t_vec := Vector3(S["tx"][i], S["ty"][i], S["tz"][i])
	var s_off := d.dot(t_vec)
	var hw: float = S["half"][i]
	var edge := hw + KERB_W
	var lat := d.dot(Vector3(S["bx"][i], S["by"][i], S["bz"][i]))
	if absf(lat) > edge:
		var lh := d.x * float(S["hx"][i]) + d.z * float(S["hz"][i])
		if absf(lh) > edge:
			lat = lh
	var t := fposmod((i * _station_spacing + s_off) / length, 1.0)
	var out := {"t": t, "lateral": lat, "edge_ratio": absf(lat) / hw, "station": i}
	_ray.from = Vector3(p.x, p.y + 2.5, p.z)
	_ray.to = Vector3(p.x, p.y - 8.0, p.z)
	_ray.collision_mask = 1
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
	if hit.is_empty() or (hit["position"] as Vector3).y < sea_y - 0.05:
		out["y"] = sea_y
		out["normal"] = Vector3.UP
		out["surface"] = Surface.WATER if p.y < sea_y + 3.0 else Surface.OFF_TRACK
		out["valid"] = p.y < sea_y + 3.0
		return out
	out["y"] = (hit["position"] as Vector3).y
	out["normal"] = hit["normal"]
	out["valid"] = true
	var a := absf(lat)
	var surf := Surface.ROAD
	if a <= hw:
		for pad in _boost_pads:
			if t >= float(pad["t0"]) and t <= float(pad["t1"]) and absf(lat - float(pad["lat"])) <= float(pad["hw"]):
				surf = Surface.BOOST
				break
	elif a > edge:
		var left := lat < 0.0
		var shoulder: float = S["shoulderL"][i] if left else S["shoulderR"][i]
		surf = int(S["surfL"][i] if left else S["surfR"][i]) if a - edge <= shoulder else Surface.OFF_TRACK
	out["surface"] = surf
	return out


static func rumble_at(x: float, z: float) -> float:
	return sin(x * 4.7 + z * 3.1) * 0.5 + sin(x * 11.3 - z * 7.9) * 0.31 + sin(x * 23.7 + z * 19.1) * 0.19


## kart-royale Track.collideWalls: push-out for a kart of `radius` against the
## guardrail / rock / parapet tables. Returns {} or {push, normal}.
func collide_walls(p: Vector3, radius: float, hint_t: float) -> Dictionary:
	var n := station_count
	var i := find_station(p, int(fposmod(hint_t, 1.0) * n) % n)
	var d := p - Vector3(S["px"][i], S["py"][i], S["pz"][i])
	var hx: float = S["hx"][i]
	var hz: float = S["hz"][i]
	var lat := d.x * hx + d.z * hz
	var hw: float = S["half"][i]
	for side_i in 2:
		var left := side_i == 0
		var kind := int(S["wallL"][i] if left else S["wallR"][i])
		if kind == 0:
			continue
		var off: float = S["wallOffL"][i] if left else S["wallOffR"][i]
		var wall_l := hw + off
		var side := -1.0 if left else 1.0
		var pen := radius - (wall_l - side * lat)
		if pen <= 0.0:
			continue
		var foot_y: float = S["py"][i]
		if p.y > foot_y + WALL_HEIGHT[clampi(kind, 0, 3)] + 1.5:
			continue
		var nrm := Vector3(hx, 0.0, hz).normalized() * -side
		return {"push": nrm * pen, "normal": nrm}
	return {}


## Centreline sample at lap fraction t: pos, tangent, binormal (banked right), normal, half, bank.
func sample(t: float) -> Dictionary:
	var n := station_count
	var x := fposmod(t, 1.0) * n
	var i := int(x) % n
	var j := (i + 1) % n
	var u := x - floorf(x)
	var pos := Vector3(lerpf(S["px"][i], S["px"][j], u), lerpf(S["py"][i], S["py"][j], u), lerpf(S["pz"][i], S["pz"][j], u))
	var tan := Vector3(lerpf(S["tx"][i], S["tx"][j], u), lerpf(S["ty"][i], S["ty"][j], u), lerpf(S["tz"][i], S["tz"][j], u)).normalized()
	var bin := Vector3(lerpf(S["bx"][i], S["bx"][j], u), lerpf(S["by"][i], S["by"][j], u), lerpf(S["bz"][i], S["bz"][j], u)).normalized()
	var nrm := Vector3(lerpf(S["nx"][i], S["nx"][j], u), lerpf(S["ny"][i], S["ny"][j], u), lerpf(S["nz"][i], S["nz"][j], u)).normalized()
	return {"pos": pos, "tangent": tan, "binormal": bin, "normal": nrm,
		"half": lerpf(S["half"][i], S["half"][j], u), "bank": lerpf(S["bank"][i], S["bank"][j], u)}


## kart-royale cornerFactor: 0 on straights, 1 in real corners (gates drift charge).
func corner_factor(t: float) -> float:
	var n := _corner_table.size()
	if n == 0:
		return 1.0
	var i := clampi(int(fposmod(t, 1.0) * n), 0, n - 1)
	return clampf((_corner_table[i] - 0.0045) / (0.007 - 0.0045), 0.0, 1.0)


func _build_corner_table() -> void:
	var n := 512
	var tans: Array[Vector3] = []
	for i in n:
		tans.append(sample(float(i) / n)["tangent"])
	var ds := maxf(1e-3, length / n)
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in n:
		raw[i] = tans[i].cross(tans[(i + 1) % n]).length() / ds
	_corner_table.resize(n)
	for i in n:
		var m := 0.0
		for k in range(-4, 5):
			m = maxf(m, raw[posmod(i + k, n)])
		_corner_table[i] = m


# --- Build ---------------------------------------------------------------------------

func _load_data() -> void:
	var txt := FileAccess.get_file_as_string(DATA_PATH)
	var data: Dictionary = JSON.parse_string(txt)
	var fields: Array = data["fields"]
	for i in fields.size():
		_f[fields[i]] = i
	_stations = data["stations"]
	_station_spacing = data["stationSpacing"]
	sea_y = data["seaY"]
	_grid = data["grid"]
	_boost_pads = data["boostPads"]
	station_count = _stations.size()
	for col_name in _f:
		var col: int = _f[col_name]
		var arr := PackedFloat32Array()
		arr.resize(station_count)
		for i in station_count:
			arr[i] = _stations[i][col]
		S[col_name] = arr
	curve = Curve3D.new()
	curve.bake_interval = 0.5
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for s in _stations:
		var p := Vector3(s[_f["px"]], s[_f["py"]], s[_f["pz"]])
		curve.add_point(p)
		_half.append(s[_f["half"]])
		minimap_points.append(Vector2(p.x, p.z))
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	var s0: Array = _stations[0]
	curve.add_point(Vector3(s0[_f["px"]], s0[_f["py"]], s0[_f["pz"]]))
	length = curve.get_baked_length()
	center = Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)
	island_radius = (hi - lo).length() * 0.5


func _build_geometry() -> void:
	for path in [TRACK_GLB, SCENERY_GLB]:
		var scene: PackedScene = load(path)
		if scene == null:
			push_error("Missing %s - run tools/kart_royale_export" % path)
			continue
		var root := scene.instantiate() as Node3D
		add_child(root)
		Toon.apply(root)
		if path == TRACK_GLB:
			_add_collision(root)
	# Shadows only from things near the road; the far backdrop and props are cheap flats.
	for mi in find_children("*", "MeshInstance3D", true, false):
		var n := String(mi.name)
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if n in ["terrain", "backdrop", "road", "markings", "shoulders", "kerbs"] else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _add_collision(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var n := String(m.name)
		if not (n in DRIVABLE or n in SOLID):
			continue
		var shape := m.mesh.create_trimesh_shape()
		if shape == null:
			continue
		var body := StaticBody3D.new()
		body.name = n + "_col"
		# Layer 1 = ground the wheels probe; layer 2 = solid props the probe must ignore.
		body.collision_layer = 1 if n in DRIVABLE else 2
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		m.add_child(body)


## kart-royale places walls at (half-width + offset) along the horizontal right.
func _wall_point(s: Array, off_col: int, sign_lat: float) -> Vector3:
	var p := Vector3(s[_f["px"]], s[_f["py"]], s[_f["pz"]])
	var t := Vector3(s[_f["tx"]], 0.0, s[_f["tz"]]).normalized()
	var right := t.cross(Vector3.UP).normalized()
	return p + right * sign_lat * (float(s[_f["half"]]) + float(s[off_col]))


func _build_sea() -> void:
	var sea := PlaneMesh.new()
	sea.size = Vector2(9000, 9000)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/water.gdshader")
	mat.set_shader_parameter("center", Vector2(center.x, center.z))
	mat.set_shader_parameter("shore_radius", -100.0)  # open sea: no island foam rings
	var mi := MeshInstance3D.new()
	mi.name = "Sea"
	mi.mesh = sea
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(center.x, sea_y - 0.05, center.z)
	add_child(mi)


func _plan_pickups() -> void:
	# kart-royale item box rows (BOX_ROWS), lanes spaced 3.1 m across the road (3..8).
	for frac in [0.052, 0.148, 0.246, 0.336, 0.428, 0.505, 0.646, 0.712, 0.802, 0.906]:
		var o: float = length * frac
		var hw := half_width_at(o) - 1.8
		var lanes := clampi(int(floorf(hw * 2.0 / 3.1)) + 1, 3, 8)
		for k in lanes:
			var lat := lerpf(-hw, hw, k / float(lanes - 1))
			item_box_spots.append(transform_at(o, lat).origin + Vector3.UP * 1.05)
	for frac in [0.05, 0.22, 0.30, 0.47, 0.70, 0.78, 0.92]:
		var o: float = length * frac
		var phase := _rng.randf() * TAU
		for k in 6:
			var hw := half_width_at(o + k * 4.0)
			var lat := sin(phase + k * 0.6) * hw * 0.5
			energy_spots.append(transform_at(o + k * 4.0, lat).origin + Vector3.UP * 1.0)
