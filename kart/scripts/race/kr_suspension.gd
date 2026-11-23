class_name KRSuspension
extends RefCounted
## Four-corner suspension ported from kart-royale (src/kart/Suspension.ts, MIT).
## Works in kart-royale's kart frame: basis columns (right, up, forward), +Z forward.

const WHEEL_RADIUS := 0.36
const REST_LENGTH := 0.3
const REST_COMPRESSION := 0.12
const MAX_COMPRESSION := 0.24
const MAX_DROOP := 0.13
const HALF_TRACK := 0.66
const HALF_BASE := 0.8
const COM_HEIGHT := 0.34
const DAMP_COMPRESS := 0.44
const DAMP_REBOUND := 0.66
const TYRE_HALF_WIDTH := 0.15
const ANTI_ROLL := 58.0
const FOOTPRINT := [0.0, -0.92, 0.92]
const FOOTPRINT_EDGE_MARGIN := 1.5

class Wheel:
	var index := 0
	var front := true
	var side := 1.0
	var attach := Vector3.ZERO
	var attach_world := Vector3.ZERO
	var ground_point := Vector3.ZERO
	var ground_normal := Vector3.UP
	var ground_valid := false
	var surface := 0
	var compression := REST_COMPRESSION
	var compression_vel := 0.0
	var load := 0.0
	var contact := true
	var bottomed := false
	var contact_point := Vector3.ZERO
	var spin_angle := 0.0
	var spin_rate := 0.0
	var slip := 0.0

var wheels: Array[Wheel] = []
var roll := 0.0
var roll_vel := 0.0
var pitch := 0.0
var pitch_vel := 0.0
var ground_normal := Vector3.UP
var contacts := 4
var total_force := 0.0
var bottom_depth := 0.0
var dominant_surface := 0
var worst_surface := 0
var off_road_load := 0.0
var boost_contact := false
var grip_mul := 1.0
var drag_mul := 1.0
var max_speed_mul := 1.0
var _stiffness := 8000.0
var _roll_inertia := 60.0
var _pitch_inertia := 120.0
var _mass := 200.0


func _init() -> void:
	for i in 4:
		var w := Wheel.new()
		w.index = i
		w.front = i < 2
		w.side = -1.0 if i % 2 == 0 else 1.0
		w.attach = Vector3(w.side * HALF_TRACK, REST_LENGTH + WHEEL_RADIUS - REST_COMPRESSION, (1.0 if w.front else -1.0) * HALF_BASE)
		wheels.append(w)


func set_mass(mass: float, gravity: float) -> void:
	_mass = mass
	_stiffness = (mass * gravity) / (4.0 * REST_COMPRESSION)
	_roll_inertia = mass * 0.55 * 0.55
	_pitch_inertia = mass * 0.78 * 0.78


func reset() -> void:
	roll = 0.0
	roll_vel = 0.0
	pitch = 0.0
	pitch_vel = 0.0
	ground_normal = Vector3.UP
	contacts = 4
	dominant_surface = 0
	worst_surface = 0
	off_road_load = 0.0
	boost_contact = false
	for w in wheels:
		w.compression = REST_COMPRESSION
		w.compression_vel = 0.0
		w.load = (_mass * 20.0) / 4.0
		w.contact = true
		w.bottomed = false
		w.slip = 0.0
		w.spin_rate = 0.0
		w.ground_valid = false


static func _props(s: int) -> Array:
	return SunsetTrack.SURFACE_PROPS[clampi(s, 0, 6)]


func probe_ground(track: SunsetTrack, position: Vector3, basis: Basis, hint_t: float) -> void:
	var right := basis.x
	for w in wheels:
		w.attach_world = basis * w.attach + position
		var best_y := -INF
		var best_surface := 0
		var valid := false
		var have_frame := false
		var samples := 1
		var s := 0
		while s < samples:
			var at := w.attach_world
			var off: float = FOOTPRINT[s]
			if off != 0.0:
				at += right * (off * TYRE_HALF_WIDTH)
			s += 1
			var pr := track.probe(at, hint_t)
			if not pr["valid"]:
				continue
			if not have_frame:
				have_frame = true
				var nrm: Vector3 = pr["normal"]
				w.ground_normal = nrm.normalized() if nrm.length_squared() > 1e-6 else Vector3.UP
				var lat := absf(float(pr["lateral"]))
				var e: float = pr["edge_ratio"]
				var inside := lat * (1.0 / e - 1.0) if e > 1e-3 else INF
				if not (inside > FOOTPRINT_EDGE_MARGIN):
					samples = FOOTPRINT.size()
			var rumble: float = _props(pr["surface"])[3]
			var y: float = pr["y"] + (rumble * SunsetTrack.rumble_at(at.x, at.z) if rumble > 0.0 else 0.0)
			if y <= best_y:
				continue
			best_y = y
			best_surface = pr["surface"]
			valid = true
		w.ground_valid = valid
		if not valid:
			continue
		w.surface = best_surface
		w.ground_point = Vector3(w.attach_world.x, best_y, w.attach_world.z)


func solve(dt: float, position: Vector3, basis: Basis, up: Vector3, a_lat: float, a_long: float, airborne_righting: bool) -> float:
	var rest_dist := REST_LENGTH + WHEEL_RADIUS
	var max_load := _mass * 260.0
	var total := 0.0
	var roll_torque := 0.0
	var pitch_torque := 0.0
	var n_contacts := 0
	var normal_weight := 0.0
	var bottom := 0.0
	var n_acc := Vector3.ZERO
	dominant_surface = 0
	var best_load := -1.0
	var grip := 0.0
	var drag := 0.0
	var vmax := 0.0
	var prop_weight := 0.0
	for w in wheels:
		var prev := w.compression
		var p := basis * w.attach + position
		w.attach_world = p
		var dist := rest_dist + MAX_DROOP + 1.0
		if w.ground_valid:
			var d := p - w.ground_point
			var denom := maxf(0.25, up.dot(w.ground_normal))
			dist = d.dot(w.ground_normal) / denom
			if not is_finite(dist):
				dist = rest_dist + MAX_DROOP + 1.0
		var comp := rest_dist - dist + w.attach.x * roll + w.attach.z * pitch
		var touching := w.ground_valid and comp > -MAX_DROOP
		comp = clampf(comp, -MAX_DROOP, MAX_COMPRESSION + 0.06)
		w.compression = comp
		w.compression_vel = (comp - prev) / dt
		w.contact = touching
		w.bottomed = comp >= MAX_COMPRESSION
		if touching:
			n_contacts += 1
			var zeta := DAMP_COMPRESS if w.compression_vel >= 0.0 else DAMP_REBOUND
			var damping := 2.0 * zeta * sqrt(_stiffness * (_mass * 0.25))
			var f := _stiffness * comp + damping * w.compression_vel
			if w.bottomed:
				var over := comp - MAX_COMPRESSION
				bottom = maxf(bottom, over)
				f += _stiffness * (18.0 * over + 120.0 * over * over)
				if w.compression_vel > 0.0:
					f += damping * 2.0 * w.compression_vel
			f = clampf(f, 0.0, max_load)
			w.load = f
			total += f
			roll_torque -= f * w.attach.x
			pitch_torque -= f * w.attach.z
			w.contact_point = p + up * (comp - rest_dist)
			n_acc += w.ground_normal * (f + 1.0)
			normal_weight += f + 1.0
			var props := _props(w.surface)
			var pw := f + 1.0
			grip += props[0] * pw
			drag += props[1] * pw
			vmax += props[2] * pw
			prop_weight += pw
			if f > best_load:
				best_load = f
				dominant_surface = w.surface
		else:
			w.load = 0.0
			w.contact_point = p + up * -(rest_dist + MAX_DROOP)
	contacts = n_contacts
	total_force = total
	bottom_depth = bottom
	_classify_surfaces(total)
	if normal_weight > 0.0:
		n_acc /= normal_weight
		if n_acc.length_squared() > 1e-6:
			ground_normal = n_acc.normalized()
	if prop_weight > 0.0:
		grip_mul = grip / prop_weight
		drag_mul = drag / prop_weight
		max_speed_mul = vmax / prop_weight
	else:
		grip_mul = 1.0
		drag_mul = 1.0
	roll_torque -= _mass * a_lat * COM_HEIGHT
	pitch_torque -= _mass * a_long * COM_HEIGHT
	var arb := _mass * ANTI_ROLL
	roll_torque += -arb * roll - _mass * 2.2 * roll_vel
	if airborne_righting:
		var k := 26.0 * _roll_inertia
		roll_torque += -roll * k - roll_vel * 2.0 * sqrt(k * _roll_inertia)
		var kp := 26.0 * _pitch_inertia
		pitch_torque += -pitch * kp - pitch_vel * 2.0 * sqrt(kp * _pitch_inertia)
	roll_vel += (roll_torque / _roll_inertia) * dt
	pitch_vel += (pitch_torque / _pitch_inertia) * dt
	roll += roll_vel * dt
	pitch += pitch_vel * dt
	var lim := 0.26
	if roll > lim:
		roll = lim
		roll_vel = minf(roll_vel, 0.0)
	elif roll < -lim:
		roll = -lim
		roll_vel = maxf(roll_vel, 0.0)
	if pitch > lim:
		pitch = lim
		pitch_vel = minf(pitch_vel, 0.0)
	elif pitch < -lim:
		pitch = -lim
		pitch_vel = maxf(pitch_vel, 0.0)
	if not is_finite(roll) or not is_finite(pitch):
		roll = 0.0
		pitch = 0.0
		roll_vel = 0.0
		pitch_vel = 0.0
	return total


func _classify_surfaces(total: float) -> void:
	var floor_load := total * 0.05
	var worst := 0
	var worst_pen := -INF
	var fatal := 0
	var fatal_pen := -INF
	var engaged := 0
	var clean := 0
	var off_road := 0.0
	var boost := false
	for w in wheels:
		if not w.contact or w.load <= floor_load:
			continue
		engaged += 1
		var s := w.surface
		if s == SunsetTrack.Surface.BOOST:
			boost = true
		if s != SunsetTrack.Surface.ROAD and s != SunsetTrack.Surface.BOOST:
			off_road += w.load
		var pen: float = 1.0 - _props(s)[2]
		if s == SunsetTrack.Surface.OFF_TRACK or s == SunsetTrack.Surface.WATER:
			if pen > fatal_pen:
				fatal_pen = pen
				fatal = s
		else:
			clean += 1
			if pen > worst_pen:
				worst_pen = pen
				worst = s
	boost_contact = boost
	off_road_load = off_road / total if total > 1.0 else 0.0
	if engaged == 0:
		worst_surface = dominant_surface
	elif clean == 0:
		worst_surface = fatal
	else:
		worst_surface = worst


func visual_offset(w: Wheel) -> float:
	var lo := -(MAX_DROOP + REST_COMPRESSION)
	var hi := MAX_COMPRESSION + 0.06 - REST_COMPRESSION
	return clampf(w.compression - REST_COMPRESSION, lo, hi)
