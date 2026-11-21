class_name Kart
extends Node3D
## Kart physics ported from kart-royale (src/kart/Kart.ts, MIT): 120 Hz substeps,
## four-corner suspension, friction-circle tyres, yaw dynamics, hop-drift with
## three charge tiers, boosts, spin-outs, landings, wall and kart collisions and a
## respawn watchdog. On top sits Loop GP's game layer: items, energy, shield and
## comic effects.
##
## Frames: the simulation runs in kart-royale's convention, basis (right, up,
## forward) with forward = +Z of that basis. The node itself uses Godot's
## convention (forward = -Z), so its basis is (-right, up, -forward).

signal item_changed(kart: Kart)
signal hit_taken(kart: Kart)
signal bumped(kart: Kart, other: Kart, impulse: float)
## Camera / effects cues: "land" (impact), "collide" (impulse), "boost" (tier), "hit".
signal fx(kind: String, value: float)

enum DriftLevel { NONE, BLUE, ORANGE, PURPLE }
const DRIFT_COLORS := [Color.WHITE, Color("3fb8ff"), Color("ff8a1f"), Color("c04cff")]

# --- kart-royale constants -----------------------------------------------------------
const GRAVITY := 20.0
const BASE_MASS := 200.0
const BASE_TOP_SPEED := 30.0
const SUBSTEP := 1.0 / 120.0
const MAX_SUBSTEPS := 6
const KART_RADIUS := 0.86
const WHEELBASE := KRSuspension.HALF_BASE * 2.0
const MAX_STEER := 0.55
const STEER_RATE_LOW := 10.5
const STEER_RATE_HIGH := 5.6
const STEER_RATE_FREE := 15.0
const MAX_DRIVE := 3000.0
const BRAKE_FORCE := 4200.0
const REVERSE_FORCE := 1500.0
const MAX_REVERSE := 8.0
const ROLL_DRAG := 0.95
const AERO_DRAG := 0.46
const HOP_SPEED := 3.05
const DRIFT_REAR_GRIP_IN := 0.98
const DRIFT_REAR_GRIP_OUT := 0.6
const DRIFT_TIERS := [0.55, 0.95, 1.9]
const DRIFT_CARRY_TIME := 0.8
const DRIFT_RELEASE_GRACE := 0.3
const DRIFT_STRAIGHT_BAIL := 1.0
const DRIFT_BOOST_TIME := [0.0, 0.95, 1.8, 3.0]
const DRIFT_BOOST_STRENGTH := [1.0, 1.12, 1.25, 1.36]
const DRIFT_ENGAGE_STEER := 0.13
const DRIFT_ARM_TIME := 0.8
const DRIFT_SLIP_OUT := 0.06
const DRIFT_SLIP_IN := 0.2
const DRIFT_SLIP_GAIN := 2.6
const DRIFT_MAX_YAW := 26.0
const DRIFT_TURN_ASSIST := 6.0
const DRIFT_TURN_RELIEF := 2.2
const DRIFT_POSE_BASE := 0.33
const DRIFT_POSE_TIER := 0.19
const DRIFT_POSE_LOCK := 0.05
const DRIFT_POSE_MAX := 0.62
const DRIFT_BODY_ROLL := 0.15
const DRIFT_POSE_STEER := 0.14
const POSE_SPEED_FULL := 9.0
const DRIFT_THRUST := 3.0
const AIR_STEER := 1.5
const WALL_RESTITUTION := 0.28
const KART_RESTITUTION := 0.42

# --- identity / race ---------------------------------------------------------------
var racer_index := 0
var display_name := ""
var racer: Dictionary
var is_player := false
var controller: KartController
var race: Node
var speed_mult := 1.0  # top-speed multiplier (difficulty)
var input_enabled := false

# --- kart-royale state ------------------------------------------------------------------
var position_k := Vector3.ZERO   # simulation position (node origin follows it)
var velocity := Vector3.ZERO
var fwd := Vector3(0, 0, 1)      # kart-royale forward
var right_k := Vector3(1, 0, 0)  # kart-royale right
var up_k := Vector3.UP
var yaw := 0.0
var yaw_rate := 0.0
var steer_input := 0.0
var steer_angle := 0.0
var speed := 0.0                 # forward speed, m/s
var top_speed := BASE_TOP_SPEED
var max_speed := BASE_TOP_SPEED  # for HUD / camera scaling
var t := 0.0                     # lap fraction from the track probe
var surface := 0
var off_road_load := 0.0
var offroad := false
var airborne := false
var boost_time := 0.0
var boost_strength := 1.0
var spin_time := 0.0             # = kart-royale stunTime
var invuln_time := 0.0
var drift_dir := 0.0
var drift_charge := 0.0
var drift_level := 0             # = kart-royale driftTier
var suspension := KRSuspension.new()
var _mass := BASE_MASS
var _yaw_inertia := BASE_MASS * 0.42
var _want_drift_prev := false
var _hop_timer := 0.0
var _drift_time := 0.0
var _drift_carry := 0.0
var _drift_carry_time := 0.0
var _drift_grace := 0.0
var _drift_straight := 0.0
var _drift_beta := 0.0
var _air_time := 0.0
var _air_descent := 0.0
var _a_lat := 0.0
var _a_long := 0.0
var _a_lat_pure := 0.0
var _squash_time := 0.0
var _squash_len := 0.3
var _spin_dir := 1.0
var _pose_phase := 0.0
var _pose_dir := 0.0
var _drift_pose_yaw := 0.0
var _pose_steer := 0.0
var _last_good_t := 0.0
var _bad_surface_time := 0.0
var _collide_cooldown := 0.0
var _ground_y := 0.0
var _respawn_pending := false

# --- game layer -------------------------------------------------------------------------
var star_time := 0.0     # RAMPAGE: invincible, rams rivals aside
var shrink_time := 0.0   # ZAP!: shrunk and slowed
var item := ""
var item_count := 0
var roulette_time := 0.0
var energy := 0.0
var squash := 0.0
var lap := 0
var track_offset := 0.0
var total_progress := 0.0
var place := 1
var finished := false
var finish_time := -1.0
var lap_start_time := 0.0
var best_lap := -1.0
var wrong_way_time := 0.0
var stuck_time := 0.0

# --- visuals ------------------------------------------------------------------------------
var model: Node3D
var _visual: Node3D
var _wheel_nodes: Array[Node3D] = [null, null, null, null]  # kart-royale wheel order
var _wheel_rest_y := [0.36, 0.36, 0.36, 0.36]
var _head: Node3D
var _sparks: Array[CPUParticles3D] = []
var _flame: CPUParticles3D
var _dust: CPUParticles3D
var _shield_mesh: MeshInstance3D


func setup(index: int, racer_data: Dictionary, ctrl: KartController, player: bool) -> void:
	racer_index = index
	racer = racer_data
	display_name = racer_data["name"]
	controller = ctrl
	is_player = player
	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)
	model = Props.make_kart(racer_data, index)
	_visual.add_child(model)
	# kart-royale wheel order: 0 front/side-1, 1 front/side+1, 2 rear/side-1, 3 rear/side+1.
	# Their side -1 is the kart's geometric right (our +X).
	var names := ["WheelFR", "WheelFL", "WheelRR", "WheelRL"]
	for i in 4:
		var w := model.find_child(names[i], true, false) as Node3D
		_wheel_nodes[i] = w
		if w:
			_wheel_rest_y[i] = w.position.y
	_head = model.find_child("Head", true, false) as Node3D
	_mass = BASE_MASS
	_yaw_inertia = _mass * 0.42
	suspension.set_mass(_mass, GRAVITY)
	suspension.reset()
	_build_effects()


# --- public API (used by race, items, AI, HUD, camera) ------------------------------------

func forward() -> Vector3:
	return fwd


func set_camera_hidden(hidden: bool) -> void:
	if _visual and _visual.visible == hidden:
		_visual.visible = not hidden


func is_drifting() -> bool:
	return drift_dir != 0.0


func is_boosting() -> bool:
	return boost_time > 0.0


func place_at(tr: Transform3D) -> void:
	var f := -tr.basis.z
	_set_pose(tr.origin, atan2(f.x, f.z))


func _set_pose(pos: Vector3, new_yaw: float) -> void:
	position_k = pos
	yaw = new_yaw
	yaw_rate = 0.0
	velocity = Vector3.ZERO
	up_k = Vector3.UP
	speed = 0.0
	steer_input = 0.0
	steer_angle = 0.0
	_a_lat = 0.0
	_a_long = 0.0
	_a_lat_pure = 0.0
	_forfeit_drift()
	boost_time = 0.0
	boost_strength = 1.0
	spin_time = 0.0
	airborne = false
	_air_time = 0.0
	suspension.reset()
	_update_basis(1.0)
	_sync_node()
	if is_inside_tree():
		reset_physics_interpolation()


func start_boost(seconds: float, strength := 1.18) -> void:
	if seconds <= 0.0:
		return
	boost_time = maxf(boost_time, seconds)
	boost_strength = maxf(boost_strength, clampf(strength, 1.0, 1.6))
	Game.sfx("boost", global_position)


## kart-royale spinOut. Returns true if the hit landed (RAMPAGE and respawn grace ignore it).
func take_hit(seconds := 1.3) -> bool:
	if star_time > 0.0 or invuln_time > 0.0:
		return false
	spin_time = maxf(spin_time, seconds)
	_spin_dir = -drift_dir if drift_dir != 0.0 else (signf(steer_input) if steer_input != 0.0 else 1.0)
	_forfeit_drift()
	boost_time = 0.0
	boost_strength = 1.0
	velocity *= 0.45
	energy = maxf(energy - 20.0, 0.0)
	hit_taken.emit(self)
	fx.emit("hit", 1.0)
	return true


## kart-royale squash: flattened, stunned and slowed (ZAP!).
func squash_hit(seconds: float) -> bool:
	if star_time > 0.0 or invuln_time > 0.0:
		return false
	spin_time = maxf(spin_time, seconds)
	_squash_time = seconds
	_squash_len = maxf(0.05, seconds)
	velocity *= 0.25
	boost_time = 0.0
	boost_strength = 1.0
	_forfeit_drift()
	fx.emit("hit", 1.0)
	return true


## kart-royale launch: add an impulse (explosions, RAMPAGE rams).
func launch(impulse: Vector3) -> void:
	if impulse.is_finite():
		velocity += impulse
		if impulse.dot(up_k) > 1.0:
			_air_descent = 0.0


func give_item_box() -> bool:
	if item != "" or roulette_time > 0.0:
		return false
	item_count = 0
	roulette_time = 1.1
	Game.sfx("item_roulette", global_position)
	return true


func add_energy(v: float) -> void:
	energy = minf(energy + v, 100.0)


func respawn() -> void:
	_respawn_pending = true


# --- frame ------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var track: SunsetTrack = race.track if race else null
	if track == null:
		return
	if controller:
		controller.update(self, delta)
	var c := controller
	var steer := 0.0
	var throttle := 0.0
	var brake := 0.0
	var want_drift := false
	if finished:
		throttle = 0.45
		steer = _autopilot_steer()
	elif input_enabled:
		steer = c.steer
		throttle = c.throttle
		brake = c.brake
		want_drift = c.drift
	else:
		brake = 1.0  # held on the grid
	_update_game_timers(delta)
	step(track, delta, steer, throttle, brake, want_drift)


## kart-royale Kart.step. steer: +1 = full right lock.
func step(track: SunsetTrack, dt: float, steer: float, throttle: float, brake: float, want_drift: bool) -> void:
	if _respawn_pending:
		_do_respawn(track)
	dt = clampf(dt, 1.0 / 480.0, 1.0 / 20.0)
	if boost_time > 0.0:
		boost_time -= dt
		if boost_time <= 0.0:
			boost_time = 0.0
			boost_strength = 1.0
	invuln_time = maxf(0.0, invuln_time - dt)
	if _collide_cooldown > 0.0:
		_collide_cooldown -= dt
	_squash_time = maxf(0.0, _squash_time - dt)
	if _hop_timer > 0.0:
		_hop_timer -= dt
	var stunned := spin_time > 0.0
	if stunned:
		spin_time -= dt
		steer = 0.0
		throttle = 0.0
		brake = 0.0
		want_drift = false
	var pr := track.probe(position_k, t)
	t = pr["t"]
	_ground_y = pr["y"]
	var centre_surface: int = pr["surface"]
	var lead := velocity * (dt * 0.5)
	if lead.length() > 0.8:
		lead = lead.normalized() * 0.8
	suspension.probe_ground(track, position_k + lead, _sim_basis(), t)
	var n := mini(MAX_SUBSTEPS, maxi(1, ceili(dt / SUBSTEP)))
	var h := dt / n
	for i in n:
		_update_steer_input(h, steer)
		_update_drift_state(track, h, want_drift)
		_substep(h, throttle, brake, stunned)
		_collide_walls(track)
		_collide_karts(h)
		_update_airborne(h)
	var grounded := suspension.contacts > 0
	var holding: int = suspension.dominant_surface if grounded else centre_surface
	surface = suspension.worst_surface if grounded else centre_surface
	off_road_load = suspension.off_road_load if grounded else 0.0
	offroad = off_road_load > 0.4
	if grounded and suspension.boost_contact and boost_time < 0.9:
		start_boost(1.1, 1.28)
	var bad := holding == SunsetTrack.Surface.WATER or holding == SunsetTrack.Surface.OFF_TRACK
	if grounded and float(pr["edge_ratio"]) < 1.25 and not bad:
		_last_good_t = t
		_bad_surface_time = 0.0
	elif bad:
		_bad_surface_time += dt
	if position_k.y < _ground_y - 30.0 or _bad_surface_time > 2.2:
		_do_respawn(track)
	_sync_node()
	_update_visuals(dt)


func _sim_basis() -> Basis:
	return Basis(right_k, up_k, fwd)


func _sync_node() -> void:
	global_transform = Transform3D(Basis(-right_k, up_k, -fwd), position_k)


func _update_steer_input(h: float, steer: float) -> void:
	var want := -steer
	var cur := steer_input
	var loading := want * cur >= 0.0 and absf(want) > absf(cur)
	var rate := lerpf(STEER_RATE_LOW, STEER_RATE_HIGH, clampf(absf(speed) / maxf(6.0, top_speed), 0.0, 1.0)) if loading else STEER_RATE_FREE
	steer_input = move_toward(cur, want, rate * h)


func _update_airborne(h: float) -> void:
	if suspension.contacts > 0:
		if airborne:
			_on_landing()
		else:
			_air_time = 0.0
	else:
		_air_time += h
		if _air_time > 0.06:
			airborne = true


static func _smooth(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)


func _substep(h: float, throttle: float, brake: float, stunned: bool) -> void:
	var sus := suspension
	_update_basis(h)
	var lat_before := velocity.dot(right_k)
	var fwd_before := velocity.dot(fwd)
	if sus.contacts == 0:
		_air_descent = maxf(_air_descent, -velocity.dot(up_k))
	var spring_f := sus.solve(h, position_k, _sim_basis(), up_k, _a_lat, _a_long, sus.contacts == 0)
	var grounded := sus.contacts > 0
	velocity += up_k * ((spring_f / _mass) * h)
	velocity.y -= GRAVITY * h
	if sus.bottom_depth > 0.0:
		var v_up := velocity.dot(up_k)
		if v_up < 0.0:
			velocity += up_k * (-v_up * 1.22 * clampf(sus.bottom_depth / 0.05, 0.0, 1.0))
	var surf_max := sus.max_speed_mul if grounded else 1.0
	var boosting := boost_time > 0.0
	top_speed = BASE_TOP_SPEED * speed_mult * surf_max * (boost_strength if boosting else 1.0) * (1.06 if star_time > 0.0 else 1.0)
	var vf := fwd_before
	speed = vf
	var drive := 0.0
	if not stunned:
		if throttle > 0.0:
			var r := clampf(vf / maxf(4.0, top_speed), 0.0, 1.0)
			drive += MAX_DRIVE * throttle * (1.0 - 0.8 * r * r * r) * (1.7 if boosting else 1.0)
		var stop_cap := (_mass * maxf(0.0, vf)) / h
		if brake > 0.0:
			if vf > 0.4:
				drive -= minf(BRAKE_FORCE * brake, stop_cap)
			elif throttle <= 0.0 and vf > -MAX_REVERSE and input_enabled:
				drive -= REVERSE_FORCE * brake
		elif throttle <= 0.0 and not boosting and vf > 0.5:
			drive -= minf(400.0, stop_cap)
	drive = clampf(drive, -MAX_DRIVE * 3.0, MAX_DRIVE * 3.0)
	var drifting := drift_dir != 0.0 and grounded
	var inward := clampf(steer_input * drift_dir, -1.0, 1.0) if drifting else 0.0
	var rear_grip_mul := lerpf(DRIFT_REAR_GRIP_OUT, DRIFT_REAR_GRIP_IN, (inward + 1.0) * 0.5) if drifting else 1.0
	var steer_falloff := 0.32 + 0.68 / (1.0 + absf(vf) * 0.075)
	var rack_target := MAX_STEER * steer_falloff * (clampf(drift_dir * 0.45 + steer_input * 0.95, -1.0, 1.0) if drifting else steer_input)
	steer_angle += (rack_target - steer_angle) * _smooth(26.0, h)
	var corner_mass := _mass * 0.3
	var drive_rear := drive * 0.5 if drive > 0.0 else drive * 0.2
	var drive_front := 0.0 if drive > 0.0 else drive * 0.3
	for w in sus.wheels:
		if not w.contact or w.load <= 0.0:
			w.slip = 0.0
			w.spin_rate += (vf / KRSuspension.WHEEL_RADIUS - w.spin_rate) * _smooth(2.5, h)
			continue
		var wheel_f := fwd
		if w.front and absf(steer_angle) > 1e-4:
			wheel_f = wheel_f.rotated(up_k, steer_angle)
		wheel_f -= w.ground_normal * wheel_f.dot(w.ground_normal)
		if wheel_f.length_squared() < 1e-8:
			wheel_f = fwd
		wheel_f = wheel_f.normalized()
		var wheel_r := w.ground_normal.cross(wheel_f)
		wheel_r = wheel_r.normalized() if wheel_r.length_squared() > 1e-8 else right_k
		var arm := w.contact_point - position_k
		var contact_vel := (up_k * yaw_rate).cross(arm) + velocity
		var v_long := contact_vel.dot(wheel_f)
		var v_lat := contact_vel.dot(wheel_r)
		var grip: float = KRSuspension._props(w.surface)[0]
		if not w.front:
			grip *= rear_grip_mul
		if stunned:
			grip *= 0.45
		if star_time > 0.0:
			grip *= 1.05
		var res := KRTyre.solve(KRTyre.FRONT if w.front else KRTyre.REAR, v_long, v_lat, w.load, grip,
			drive_front if w.front else drive_rear, corner_mass, h)
		var force: Vector3 = wheel_f * float(res[0]) + wheel_r * float(res[1])
		var fmax := _mass * 400.0
		if force.length_squared() > fmax * fmax:
			force = force.normalized() * fmax
		velocity += force * (h / _mass)
		yaw_rate += (up_k.dot(arm.cross(force)) / _yaw_inertia) * h
		w.slip = res[3]
		var rolling := v_long / KRSuspension.WHEEL_RADIUS
		var slip_spin := (float(res[0]) / maxf(1.0, w.load)) * 4.5
		w.spin_rate += (rolling + slip_spin - w.spin_rate) * _smooth(18.0, h)
	if boosting and grounded and vf < top_speed:
		velocity += fwd * (10.0 * clampf((boost_strength - 1.0) / 0.3, 0.0, 1.3) * h)
	if drifting and throttle > 0.0 and vf < top_speed * 0.96:
		velocity += fwd * (DRIFT_THRUST * throttle * h)
	if grounded and not stunned:
		var grip_blend := clampf(sus.grip_mul, 0.3, 1.2)
		if drifting:
			var assist := DRIFT_TURN_ASSIST * inward if inward >= 0.0 else DRIFT_TURN_RELIEF * inward
			velocity += right_k * (drift_dir * assist * grip_blend * h)
			var v := maxf(6.0, Vector2(lat_before, fwd_before).length())
			var beta := atan2(lat_before, maxf(2.0, absf(fwd_before)))
			var target := -drift_dir * lerpf(DRIFT_SLIP_OUT, DRIFT_SLIP_IN, (inward + 1.0) * 0.5)
			var yaw_cap := (DRIFT_MAX_YAW * grip_blend) / v
			var slip_yaw := clampf(_a_lat_pure / v - clampf(target - beta, -0.45, 0.45) * DRIFT_SLIP_GAIN, -yaw_cap, yaw_cap)
			var escape := clampf(-inward, 0.0, 1.0)
			var max_yaw := (24.0 * grip_blend) / maxf(5.0, absf(fwd_before))
			var rack_yaw := clampf((fwd_before / WHEELBASE) * tan(steer_angle), -max_yaw, max_yaw)
			var desired := lerpf(slip_yaw, rack_yaw, escape * escape)
			yaw_rate += clampf(desired - yaw_rate, -2.5, 2.5) * 6.0 * h
			if drift_dir * (yaw_rate - desired) > 0.35:
				yaw_rate = desired + drift_dir * 0.35
			_drift_beta = beta
		else:
			velocity += right_k * (-lat_before * clampf(2.4 * grip_blend * h, 0.0, 0.4))
			var max_yaw := (24.0 * grip_blend) / maxf(5.0, absf(fwd_before))
			var target := clampf((fwd_before / WHEELBASE) * tan(steer_angle), -max_yaw, max_yaw)
			yaw_rate += clampf(target - yaw_rate, -3.0, 3.0) * 3.4 * grip_blend * h
	elif not grounded and not stunned:
		yaw_rate += (steer_input * AIR_STEER - yaw_rate) * _smooth(3.2, h)
	if not stunned:
		var planar_speed := Vector2(lat_before, fwd_before).length()
		if planar_speed > 5.0:
			var beta := atan2(lat_before, absf(fwd_before))
			var excess := absf(beta) - (0.62 if drift_dir != 0.0 else 0.45)
			if excess > 0.0:
				yaw_rate += signf(beta) * minf(excess, 0.8) * 45.0 * h
	else:
		yaw_rate += (_spin_dir * 9.0 - yaw_rate) * _smooth(9.0, h)
	yaw_rate = clampf(yaw_rate, -7.0, 7.0)
	yaw_rate -= yaw_rate * clampf(1.1 * h, 0.0, 0.5)
	var planar := velocity
	if grounded:
		planar -= up_k * planar.dot(up_k)
	var sp := planar.length()
	if sp > 1e-4:
		var drag_mul := sus.drag_mul if grounded else 1.0
		var rolling_drag := ROLL_DRAG * _mass * drag_mul if grounded else 0.0
		var aero := AERO_DRAG * sp * sp * (0.55 if boosting else 1.0)
		var dv := minf(sp, ((rolling_drag + aero) / _mass) * h)
		velocity += planar * (-dv / sp)
	var vf_now := velocity.dot(fwd)
	if vf_now > top_speed:
		velocity += fwd * ((top_speed - vf_now) * minf(1.0, 4.0 * h))
	elif vf_now < -MAX_REVERSE:
		velocity += fwd * ((-MAX_REVERSE - vf_now) * minf(1.0, 6.0 * h))
	yaw += yaw_rate * h
	position_k += velocity * h
	var lat_now := velocity.dot(right_k)
	var fwd_now := velocity.dot(fwd)
	var a_lat_specific := (lat_now - lat_before) / h
	var a_lat_raw := a_lat_specific + yaw_rate * fwd_now
	var a_long_raw := (fwd_now - fwd_before) / h - yaw_rate * lat_now
	var k := _smooth(24.0, h)
	_a_lat_pure += (clampf(a_lat_specific, -45.0, 45.0) - _a_lat_pure) * k
	_a_lat += (clampf(a_lat_raw, -45.0, 45.0) - _a_lat) * k
	_a_long += (clampf(a_long_raw, -45.0, 45.0) - _a_long) * k
	speed = fwd_now
	_sanitize()


func _update_basis(h: float) -> void:
	var target_up := suspension.ground_normal if suspension.contacts > 0 else Vector3.UP
	var rate := 15.0 if suspension.contacts > 0 else 3.2
	up_k = up_k.lerp(target_up, _smooth(rate, h))
	if not (up_k.length_squared() > 1e-6) or not (up_k.y > 0.15):
		up_k = Vector3.UP
	up_k = up_k.normalized()
	var fwd_flat := Vector3(sin(yaw), 0.0, cos(yaw))
	var r := up_k.cross(fwd_flat)
	right_k = r.normalized() if r.length_squared() > 1e-8 else Vector3(1, 0, 0)
	fwd = right_k.cross(up_k).normalized()


func _sanitize() -> void:
	if position_k.is_finite() and velocity.is_finite() and is_finite(yaw) and is_finite(yaw_rate):
		return
	velocity = Vector3.ZERO
	yaw_rate = 0.0
	if not is_finite(yaw):
		yaw = 0.0
	_respawn_pending = true


func _tier_for(time: float) -> int:
	if time >= DRIFT_TIERS[2]:
		return 3
	if time >= DRIFT_TIERS[1]:
		return 2
	return 1 if time >= DRIFT_TIERS[0] else 0


func _charge_for(time: float) -> float:
	var tier := _tier_for(time)
	if tier >= 3:
		return 1.0
	var lo: float = 0.0 if tier == 0 else DRIFT_TIERS[tier - 1]
	var hi: float = DRIFT_TIERS[tier]
	return clampf((time - lo) / maxf(0.01, hi - lo), 0.0, 1.0)


func _update_drift_state(track: SunsetTrack, dt: float, want_drift: bool) -> void:
	var pressed := want_drift and not _want_drift_prev
	_want_drift_prev = want_drift
	var grounded := suspension.contacts > 0
	var sp := Vector2(velocity.x, velocity.z).length()
	if pressed and grounded and spin_time <= 0.0 and sp > 4.0 and drift_dir == 0.0:
		velocity += up_k * HOP_SPEED
		_hop_timer = DRIFT_ARM_TIME
		_air_descent = 0.0
		Game.sfx("drift_start", global_position)
	var cornering := absf(yaw_rate) > 0.18 and sp > 8.0
	var engage_dir := 0.0
	if absf(steer_input) > DRIFT_ENGAGE_STEER:
		engage_dir = signf(steer_input)
	elif cornering and absf(steer_input) > 0.02 and signf(steer_input) == signf(yaw_rate):
		engage_dir = signf(yaw_rate)
	if _drift_carry_time > 0.0:
		_drift_carry_time -= dt
		if _drift_carry_time <= 0.0:
			_drift_carry_time = 0.0
			_drift_carry = 0.0
	if drift_dir == 0.0 and want_drift and _hop_timer > 0.0 and engage_dir != 0.0 and sp > 4.0:
		drift_dir = engage_dir
		_drift_time = _drift_carry if _drift_carry_time > 0.0 else 0.0
		_drift_carry = 0.0
		_drift_carry_time = 0.0
		_drift_grace = DRIFT_RELEASE_GRACE
		_drift_straight = 0.0
		drift_level = _tier_for(_drift_time)
		drift_charge = _charge_for(_drift_time)
	if drift_dir != 0.0:
		var escaping := steer_input * drift_dir < -0.6
		var corner := track.corner_factor(t)
		var let_go := not want_drift
		if not let_go:
			_drift_grace = DRIFT_RELEASE_GRACE
		elif drift_level == 0 and not escaping and corner > 0.5 and _drift_grace > 0.0:
			_drift_grace -= dt
			let_go = _drift_grace <= 0.0
		else:
			_drift_grace = 0.0
		if corner > 0.5:
			_drift_straight = 0.0
		else:
			_drift_straight += dt
		var bail := let_go or sp < 3.5 or spin_time > 0.0 or _air_time > 0.8 or _drift_straight > DRIFT_STRAIGHT_BAIL
		var sur := suspension.worst_surface
		var blown := suspension.contacts > 0 and (sur == SunsetTrack.Surface.OFF_TRACK or sur == SunsetTrack.Surface.WATER)
		if blown:
			_forfeit_drift()
		elif bail:
			_release_drift()
		elif suspension.contacts > 0:
			var q := clampf((absf(_drift_beta) - 0.02) / 0.06, 0.0, 1.0)
			var on_road := clampf(1.0 - suspension.off_road_load * 1.2, 0.0, 1.0)
			_drift_time += dt * (0.85 + 0.4 * q) * on_road * corner
			var tier := _tier_for(_drift_time)
			if tier != drift_level:
				drift_level = tier
				Game.sfx("drift_spark_level", global_position)
			drift_charge = _charge_for(_drift_time)


func _forfeit_drift() -> void:
	drift_dir = 0.0
	drift_level = 0
	drift_charge = 0.0
	_drift_time = 0.0
	_drift_carry = 0.0
	_drift_carry_time = 0.0
	_drift_beta = 0.0


func _release_drift() -> void:
	var tier := drift_level
	if tier > 0:
		start_boost(DRIFT_BOOST_TIME[tier], DRIFT_BOOST_STRENGTH[tier])
		fx.emit("boost", tier)
		if race and is_player:
			race.popup(["", "ZIP!", "ZOOM!", "WHOOSH!"][tier], global_position + Vector3.UP * 2.2, DRIFT_COLORS[tier])
		_drift_carry = 0.0
		_drift_carry_time = 0.0
	elif _drift_time > 0.02:
		_drift_carry = _drift_time
		_drift_carry_time = DRIFT_CARRY_TIME
	drift_dir = 0.0
	drift_level = 0
	drift_charge = 0.0
	_drift_time = 0.0
	_drift_beta = 0.0


func _on_landing() -> void:
	airborne = false
	var impact := _air_descent
	_air_time = 0.0
	_air_descent = 0.0
	if impact > 1.5:
		_squash_time = minf(0.32, 0.1 + impact * 0.012)
		_squash_len = 0.32
		fx.emit("land", impact)
		Game.sfx("land", global_position)


func _collide_walls(track: SunsetTrack) -> void:
	var hit := track.collide_walls(position_k, KART_RADIUS, t)
	if hit.is_empty():
		return
	var n: Vector3 = hit["normal"]
	position_k += hit["push"]
	var vn := velocity.dot(n)
	if vn >= 0.0:
		return
	var spd := maxf(1.0, velocity.length())
	var squareness := clampf(-vn / spd, 0.0, 1.0)
	velocity += n * (-vn * (1.0 + WALL_RESTITUTION))
	velocity *= 1.0 - 0.5 * squareness * squareness
	velocity += n * (1.2 + 3.2 * squareness)
	var delta := wrapf(atan2(n.x, n.z) - yaw, -PI, PI)
	yaw += delta * 0.3 * squareness
	yaw_rate *= 0.55
	if drift_dir != 0.0 and squareness > 0.35:
		_release_drift()
	var impulse := -vn * (1.0 + WALL_RESTITUTION)
	if _collide_cooldown <= 0.0 and impulse > 1.5:
		_collide_cooldown = 0.12
		fx.emit("collide", impulse)
		Game.sfx("wall_hit", global_position)
		if is_player and race and impulse > 9.0:
			race.popup("BONK!", global_position + Vector3.UP * 2.0, Game.YELLOW)
			race.camera.shake(clampf(impulse * 0.02, 0.0, 0.5))


func _collide_karts(h: float) -> void:
	if race == null:
		return
	var min_dist := KART_RADIUS * 2.0
	for other: Kart in race.karts:
		if other == self:
			continue
		var sep := position_k - other.position_k
		if absf(sep.y) > 1.5:
			continue
		sep.y = 0.0
		var d2 := sep.length_squared()
		if d2 > min_dist * min_dist or d2 < 1e-6:
			continue
		var d := sqrt(d2)
		sep /= d
		var share := other._mass / (_mass + other._mass)
		position_k += sep * ((min_dist - d) * share * 0.9)
		var rel := velocity.dot(sep) - other.velocity.dot(sep)
		if rel < 0.0:
			var j := -(1.0 + KART_RESTITUTION) * rel * share
			velocity += sep * j
			yaw_rate += clampf(sep.dot(right_k) * rel * 0.06, -1.6, 1.6)
			if _collide_cooldown <= 0.0 and -rel > 2.0:
				_collide_cooldown = 0.14
				bumped.emit(self, other, -rel)
				fx.emit("collide", -rel)
		else:
			velocity += sep * (minf(4.0, (min_dist - d) * 9.0) * share * 60.0 * h)


func _do_respawn(track: SunsetTrack) -> void:
	_respawn_pending = false
	var s := track.sample(_last_good_t)
	var tan: Vector3 = s["tangent"]
	_set_pose((s["pos"] as Vector3) + (s["normal"] as Vector3) * 0.7, atan2(tan.x, tan.z))
	t = _last_good_t
	_bad_surface_time = 0.0
	invuln_time = 1.8
	if race:
		race.popup("SPLASH!" if surface == SunsetTrack.Surface.WATER else "OOPS!", position_k + Vector3.UP * 2.0, Game.BLUE)


func _autopilot_steer() -> float:
	if race == null:
		return 0.0
	var track: Track = race.track
	var target := track.point_at(track_offset + 14.0)
	var to := target - position_k
	to.y = 0.0
	# +1 = right; signed_angle_to is counter-clockwise positive around UP.
	return clampf(-fwd.signed_angle_to(to, Vector3.UP) * 2.0, -1.0, 1.0)


# --- game layer ---------------------------------------------------------------------------------

func _update_game_timers(delta: float) -> void:
	squash = maxf(squash - delta, 0.0)
	star_time = maxf(star_time - delta, 0.0)
	if shrink_time > 0.0:
		shrink_time = maxf(shrink_time - delta, 0.0)
		var u := clampf(shrink_time / 6.5, 0.0, 1.0)
		model.scale = Vector3.ONE * (0.52 + 0.48 * pow(1.0 - u, 2.2))
		var drag := -velocity * clampf(1.35 * delta, 0.0, 0.5) * u
		drag.y = 0.0
		launch(drag)
		if shrink_time <= 0.0:
			model.scale = Vector3.ONE
	if roulette_time > 0.0:
		roulette_time -= delta
		if roulette_time <= 0.0:
			item = Items.roll(place, race.karts.size() if race else 8)
			item_count = 3 if item == "turbo3" else 1
			item_changed.emit(self)
	if not input_enabled or finished:
		return
	if controller.use_item and item != "" and roulette_time <= 0.0 and spin_time <= 0.0:
		var used := item
		if race and race.use_item(self, used, controller.use_backwards):
			item_count -= 1
			if item_count <= 0:
				item = ""
				item_count = 0
			item_changed.emit(self)
	if controller.burst and energy >= 33.0 and spin_time <= 0.0:
		energy -= 33.0
		start_boost(1.1, 1.3)
		Game.sfx("energy_burst", global_position)
		if race:
			race.popup("ZOOM!", global_position + Vector3.UP * 2.2, Game.CYAN)


# --- visuals --------------------------------------------------------------------------------------

func _update_drift_pose(dt: float) -> void:
	var live := drift_dir != 0.0 and spin_time <= 0.0
	if live:
		_pose_dir = drift_dir
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var want := clampf((ground_speed - 3.0) / (POSE_SPEED_FULL - 3.0), 0.0, 1.0) if live else 0.0
	_pose_phase += (want - _pose_phase) * _smooth(9.0 if want > _pose_phase else 5.5, dt)
	var yaw_want := 0.0
	var steer_want := 0.0
	if _pose_phase > 1e-3 and _pose_dir != 0.0:
		var e := _pose_phase
		var tier_mix := clampf((drift_level + drift_charge) / 3.0, 0.0, 1.0)
		var lock := clampf(steer_input * _pose_dir, -1.0, 1.0)
		var pose := DRIFT_POSE_BASE + DRIFT_POSE_TIER * tier_mix + DRIFT_POSE_LOCK * lock
		var beta := atan2(velocity.dot(right_k), maxf(2.5, absf(velocity.dot(fwd))))
		yaw_want = clampf((beta + _pose_dir * pose) * e, -DRIFT_POSE_MAX, DRIFT_POSE_MAX)
		steer_want = _pose_dir * DRIFT_POSE_STEER * e
	else:
		_pose_phase = 0.0
		_pose_dir = 0.0
	_drift_pose_yaw += (yaw_want - _drift_pose_yaw) * _smooth(11.0, dt)
	_pose_steer += (steer_want - _pose_steer) * _smooth(13.0, dt)


func _update_visuals(dt: float) -> void:
	_update_drift_pose(dt)
	var sus := suspension
	var roll := clampf(sus.roll * 2.3, -0.3, 0.3)
	var pitch := clampf(sus.pitch * 1.7, -0.22, 0.22)
	if _pose_phase > 0.0 and _pose_dir != 0.0:
		roll = clampf(roll - _pose_dir * DRIFT_BODY_ROLL * _pose_phase, -0.38, 0.38)
	# Their body euler (pitch, poseYaw, -roll) in a +Z-forward frame; our node is
	# rotated 180 degrees about Y, which flips the sign of pitch and roll.
	_visual.rotation = Vector3(-pitch, _drift_pose_yaw, roll)
	var sq := _squash_time / maxf(0.01, _squash_len) if _squash_time > 0.0 else 0.0
	sq = maxf(sq, squash * 3.0)
	var stretch := 0.05 if boost_time > 0.0 else 0.0
	_visual.scale = Vector3(1.0 + sq * 0.18 - stretch * 0.4, 1.0 - sq * 0.3, 1.0 + sq * 0.18 + stretch)
	# Wheels: suspension travel, steering and spin.
	for i in 4:
		var node := _wheel_nodes[i]
		if node == null:
			continue
		var w := sus.wheels[i]
		node.position.y = _wheel_rest_y[i] + sus.visual_offset(w)
		if w.front:
			node.rotation.y = steer_angle + _pose_steer
		w.spin_angle = fmod(w.spin_angle + w.spin_rate * dt, TAU)
		node.rotation.x = -w.spin_angle
	if _head:
		var target := clampf(steer_input * 0.55 + drift_dir * 0.3, -0.9, 0.9)
		_head.rotation.y += (target - _head.rotation.y) * _smooth(7.0, dt)
	# Effects.
	var spark_on := drift_dir != 0.0 and drift_level > 0
	for p in _sparks:
		p.emitting = drift_dir != 0.0 and suspension.contacts > 0
		p.color = DRIFT_COLORS[drift_level] if spark_on else Color(1, 1, 1, 0.6)
	_flame.emitting = boost_time > 0.0
	_dust.emitting = off_road_load > 0.3 and absf(speed) > 5.0
	_shield_mesh.visible = star_time > 0.0
	if _shield_mesh.visible:
		_shield_mesh.rotation.y += dt * 2.0


func _build_effects() -> void:
	for x in [-0.66, 0.66]:
		var p := _particles(Color.WHITE, 0.07, 26, 0.35)
		p.position = Vector3(x, 0.1, 0.85)
		p.direction = Vector3(0, 1, 1)
		p.spread = 55.0
		p.initial_velocity_min = 2.0
		p.initial_velocity_max = 5.0
		p.gravity = Vector3(0, -12, 0)
		_visual.add_child(p)
		_sparks.append(p)
	# Short comic flame flecks from the exhausts (local, so they stay attached).
	_flame = _particles(Color("ffb21f"), 0.07, 40, 0.12)
	_flame.local_coords = true
	_flame.position = Vector3(0, 0.42, 1.0)
	_flame.direction = Vector3(0, 0.15, 1)
	_flame.spread = 10.0
	_flame.initial_velocity_min = 6.0
	_flame.initial_velocity_max = 9.0
	_flame.color_ramp = _flame_ramp()
	_flame.gravity = Vector3.ZERO
	_flame.scale_amount_curve = _shrink_curve()
	_visual.add_child(_flame)
	_dust = _particles(Color("c9b48a"), 0.35, 20, 0.6)
	_dust.position = Vector3(0, 0.15, 0.9)
	_dust.direction = Vector3(0, 1, 1)
	_dust.initial_velocity_min = 1.0
	_dust.initial_velocity_max = 3.0
	_dust.gravity = Vector3(0, 1, 0)
	_dust.scale_amount_curve = _shrink_curve()
	_visual.add_child(_dust)
	var sm := SphereMesh.new()
	sm.radius = 1.4
	sm.height = 2.4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.2, 0.32)
	_shield_mesh = MeshInstance3D.new()
	_shield_mesh.mesh = sm
	_shield_mesh.material_override = mat
	_shield_mesh.position.y = 0.7
	_shield_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shield_mesh.visible = false
	_visual.add_child(_shield_mesh)


static func _flame_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color("fff3a0"))
	g.set_color(1, Color("ff5a1f"))
	return g


static func _shrink_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 1))
	c.add_point(Vector2(1, 0))
	return c


func _particles(color: Color, size: float, amount: int, life: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var m := BoxMesh.new()
	m.size = Vector3.ONE * size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	m.material = mat
	p.mesh = m
	p.amount = amount
	p.lifetime = life
	p.emitting = false
	p.local_coords = false
	p.color = color
	return p


# --- network snapshot (for the UDP server later) ---------------------------------------------

func get_net_state() -> Dictionary:
	return {"pos": position_k, "yaw": yaw, "vel": velocity, "yaw_rate": yaw_rate,
		"drift": drift_dir, "boost": boost_time, "spin": spin_time, "lap": lap, "item": item, "energy": energy}


func apply_net_state(s: Dictionary) -> void:
	position_k = s["pos"]
	yaw = s["yaw"]
	velocity = s["vel"]
	yaw_rate = s["yaw_rate"]
	drift_dir = s["drift"]
	boost_time = s["boost"]
	spin_time = s["spin"]
