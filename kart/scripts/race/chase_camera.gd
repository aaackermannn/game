class_name ChaseCamera
extends Camera3D
## Chase camera ported from kart-royale (src/game/Camera.ts, MIT).
## A heading arm that lags the chassis and anticipates corners, on-screen framing
## that shifts the kart in bends and drifts, horizon roll with banking and turns,
## spring kicks for landings / hits / boost surges, speed-corner-brake FOV,
## ground and wall clearance, and a rotation slew limit. Our pre-race orbit and
## the "hide karts blocking the view" helper stay on top.

const FOV_BASE := 50.0
const FOV_SPEED := 5.0
const FOV_CORNER := 3.0
const FOV_BRAKE := 2.2
const PIVOT_UP := 0.62
const ARM_DIST := 5.6
const ARM_DIST_SPEED := 0.55
const ARM_HEIGHT := 1.15
const ARM_HEIGHT_SPEED := -0.22
const BOOST_DIST := 1.25
const BOOST_HEIGHT := 0.34
const BOOST_SURGE_DIST := 3.0
const BOOST_SURGE_HEIGHT := 0.50
const BOOST_SURGE_OMEGA := 13.0
const BOOST_SURGE_ZETA := 0.5
const BRAKE_DIST := 0.80
const BRAKE_HEIGHT := 0.28
const DRIFT_HEIGHT := -0.18
const DRIFT_DIST := 0.35
const AIR_HEIGHT := 0.35
const BANK_HEIGHT := 1.00
const MIN_RANGE := 2.6
const TRAVEL_GAIN := 0.60
const TRAVEL_GAIN_DRIFT := 0.55
const MAX_SLIP := 0.42
const HEAD_TAU := 0.17
const HEAD_TAU_DRIFT := 0.09
const HEAD_TAU_CORNER := 0.05
const HEAD_TAU_CALM := 0.20
const MAX_LAG := 0.455
const MAX_ARM_RATE := 2.0
const MAX_ARM_RATE_LOST := 3.2
const CALM_LO := 3.0
const CALM_HI := 12.0
const HEAD_ROAD := 0.70
const HEAD_RATE_TAU := 0.10
const CORNER_G_FULL := 9.0
const CORNER_MEASURED := 0.72
const CORNER_ANTICIPATED := 0.50
const CORNER_LOOK := 26.0
const CORNER_LOOK_SPEED := 34.0
const CORNER_TAU := 0.15
const CORNER_RATE_MAX := 1.8
const CORNER_MAX_RATE := 3.0
const FRAME_LAG_CANCEL := 0.72
const FRAME_BEND := 0.10
const FRAME_DRIFT := 0.07
const FRAME_ANG_RATE := 0.85
const FRAME_X_MAX := 0.30
const FRAME_Y := -0.19
const FRAME_Y_SPEED := -0.05
const FRAME_Y_DRIFT := -0.04
const FRAME_Y_MIN := -0.32
const FRAME_Y_MAX := -0.08
const SUBJ_UP := 0.55
const BANK_GAIN := 0.55
const CORNER_ROLL := 0.085
const DRIFT_ROLL := 0.055
const MAX_ROLL := 0.45
const MAX_ROLL_RATE := 0.95
const MAX_SLEW := 2.0
const MAX_EYE_SLIP := 14.0
const CAM_RADIUS := 0.55
const GROUND_CLEAR := 0.68
const SWEEP_STATIONS := 5
const ARM_FRAC_IN := 0.06
const ARM_FRAC_OUT := 0.22
const BASE_TOP_SPEED := 30.0

## Critically damped spring (Unity-style SmoothDamp), as in kart-royale's damp1.
class Damp:
	var v := 0.0
	var vel := 0.0

	func step(target: float, smooth_time: float, dt: float) -> float:
		var om := 2.0 / maxf(1e-4, smooth_time)
		var x := om * dt
		var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
		var change := v - target
		var temp := (vel + om * change) * dt
		vel = (vel - om * temp) * e
		v = target + (change + temp) * e
		return v

## Damped oscillator (exact solution), kart-royale's Osc.
class Osc:
	var v := 0.0
	var vel := 0.0

	func step(target: float, omega: float, zeta: float, dt: float) -> float:
		if dt <= 0.0:
			return v
		var x0 := v - target
		var v0 := vel
		if zeta < 1.0 - 1e-4:
			var wd := omega * sqrt(1.0 - zeta * zeta)
			var e := exp(-zeta * omega * dt)
			var c := cos(wd * dt)
			var s := sin(wd * dt)
			var b := (v0 + zeta * omega * x0) / wd
			v = target + e * (x0 * c + b * s)
			vel = e * ((b * wd - zeta * omega * x0) * c - (x0 * wd + zeta * omega * b) * s)
		else:
			var e := exp(-omega * dt)
			var b := v0 + omega * x0
			v = target + e * (x0 + b * dt)
			vel = e * (b - omega * (x0 + b * dt))
		return v

	func kick(a: float) -> void:
		vel += a

	func reset() -> void:
		v = 0.0
		vel = 0.0

var target: Kart
var intro_t := 0.0  # >0 while the pre-race flyover plays

var _arm_yaw := 0.0
var _arm_err := Damp.new()
var _arm := Vector3(0, 0, 1)
var _lag := Damp.new()
var _lag_yaw := 0.0
var _up := Vector3.UP
var _ready_flag := false
var _drift_signed := Damp.new()
var _drift_amt := 0.0
var _tier := Damp.new()
var _boost := Damp.new()
var _brake := Damp.new()
var _air := Damp.new()
var _calm := Damp.new()
var _corner := 0.0
var _corner_d := Damp.new()
var _bend := Damp.new()
var _bank := Damp.new()
var _look := Damp.new()
var _look_hold := 0.0
var _arm_frac := Damp.new()
var _face_yaw := 0.0
var _comp_ang := 0.0
var _fov := Osc.new()
var _dip := Osc.new()
var _kick := Osc.new()
var _surge := Osc.new()
var _trauma := 0.0
var _trauma_decay := 3.3
var _cam_t := -1.0
var _ground_y := 0.0
var _ground_init := false
var _prev_kart := Vector3.ZERO
var _prev_eye := Vector3.ZERO
var _has_prev_eye := false
var _prev_quat := Quaternion.IDENTITY
var _has_prev_quat := false
var _time := 0.0
var _eye := Vector3.ZERO
var _aim := Vector3.ZERO
var _shake_test := "--shake-test" in OS.get_cmdline_user_args()
var _orbit_pos := Vector3.ZERO


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near = 0.2
	_fov.v = FOV_BASE
	fov = FOV_BASE
	_arm_frac.v = 1.0
	if target:
		target.fx.connect(_on_kart_fx)


func _on_kart_fx(kind: String, value: float) -> void:
	match kind:
		"land":
			_dip.kick(-clampf(value * 0.055, 0.0, 1.15))
		"collide":
			_kick.kick(clampf(value * 0.035, 0.0, 1.4))
		"boost":
			_surge.kick(-4.6 - value * 0.9)
		"hit":
			_kick.kick(0.9)


## Camera shake (kart-royale addShake): trauma accumulates and decays.
func shake(amount: float, seconds := 0.3) -> void:
	_trauma = minf(1.0, _trauma + amount)
	_trauma_decay = minf(_trauma_decay, clampf(1.0 / maxf(0.08, seconds), 0.6, 6.0))


func snap() -> void:
	if target == null:
		return
	_seed()
	_orbit_pos = _kpos() + Vector3(0, 4, 0) - _kfwd() * 8.0
	global_position = _orbit_pos
	look_at(_kpos(), Vector3.UP)


func _kpos() -> Vector3:
	return target.get_global_transform_interpolated().origin


func _kfwd() -> Vector3:
	return -target.get_global_transform_interpolated().basis.z


static func _smootherstep(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)


func _process(delta: float) -> void:
	if target == null or target.race == null:
		return
	var dt := clampf(delta, 1.0 / 480.0, 0.1)
	_time += dt
	if intro_t > 0.0:
		_pose_intro(dt)
		return
	var k := target
	var track: SunsetTrack = k.race.track
	var kpos := _kpos()
	var speed := absf(k.speed)
	var sp := clampf(speed / BASE_TOP_SPEED, 0.0, 1.25)
	var drifting := k.drift_dir != 0.0 and not k.airborne
	_drift_signed.step(k.drift_dir if drifting else 0.0, 0.15 if drifting else 0.40, dt)
	_drift_amt = absf(_drift_signed.v)
	_tier.step(clampf(k.drift_level / 3.0, 0.0, 1.0) if drifting else 0.0, 0.22, dt)
	var boosting := 1.0 if k.boost_time > 0.0 else 0.0
	_boost.step(boosting, 0.11 if boosting > 0.0 else 0.30, dt)
	var braking := 1.0 if k.controller.brake > 0.4 and k.speed > 5.0 else 0.0
	_brake.step(braking, 0.20, dt)
	_air.step(1.0 if k.airborne else 0.0, 0.10 if k.airborne else 0.26, dt)
	_calm.step(_smootherstep((maxf(0.0, k.speed) - CALM_LO) / (CALM_HI - CALM_LO)), 0.28, dt)
	if Input.is_action_pressed("look_back") and k.is_player:
		_look_hold = 0.3
	else:
		_look_hold -= dt
	_look.step(1.0 if _look_hold > 0.0 and k.input_enabled else 0.0, 0.19, dt)
	# Teleport (respawn) detection: re-seed instead of swinging across the map.
	var moved := kpos.distance_to(_prev_kart)
	var cut := _ready_flag and moved > maxf(2.2, (120.0 + k.velocity.length() * 2.5) * dt)
	_prev_kart = kpos
	if not _ready_flag or cut:
		_seed()
	var s := track.sample(k.t)
	_update_up(s, dt)
	_update_heading(track, k, s, sp, speed, dt)
	_apply_fov(sp, dt)
	_pose_chase(track, k, kpos, sp, dt)
	var fx := _frame_x(dt)
	_constrain_eye(track, k, kpos, dt)
	_frame_subject(kpos, fx, _frame_y(sp))
	_apply_transform(dt)
	_hide_blockers()
	if _shake_test:
		var vis := k.model.get_global_transform_interpolated().origin if k.model else kpos
		print("SHAKE y_kart_vis=%.4f y_cam=%.4f shake=%.3f y_campos=%.4f" % [vis.y, global_position.y, _trauma, _eye.y])


func _seed() -> void:
	var f := _kfwd()
	f.y = 0.0
	if f.length_squared() > 1e-6:
		_arm_yaw = atan2(f.x, f.z)
	_arm = Vector3(sin(_arm_yaw), 0.0, cos(_arm_yaw))
	_lag_yaw = _arm_yaw
	_up = Vector3.UP
	_has_prev_quat = false
	_arm_err = Damp.new()
	_lag = Damp.new()
	_arm_frac = Damp.new()
	_arm_frac.v = 1.0
	_ground_init = false
	_cam_t = -1.0
	_has_prev_eye = false
	_dip.reset()
	_kick.reset()
	_surge.reset()
	_trauma = 0.0
	_calm = Damp.new()
	_ready_flag = true


func _update_heading(track: SunsetTrack, k: Kart, s: Dictionary, sp: float, speed: float, dt: float) -> void:
	var face := _kfwd()
	face.y = 0.0
	face = _arm if face.length_squared() < 1e-6 else face.normalized()
	var face_yaw := atan2(face.x, face.z)
	_face_yaw = face_yaw
	var slip := 0.0
	var vel := k.velocity
	vel.y = 0.0
	var vlen := vel.length()
	if vlen > 2.0:
		vel /= vlen
		var agree := vel.dot(face)
		if agree > 0.2:
			var gain := clampf((vlen - 2.0) / 5.0, 0.0, 1.0) * (TRAVEL_GAIN + TRAVEL_GAIN_DRIFT * _drift_amt) * clampf((agree - 0.2) / 0.35, 0.0, 1.0)
			slip = clampf(wrapf(atan2(vel.x, vel.z) - face_yaw, -PI, PI) * gain, -MAX_SLIP, MAX_SLIP)
	var target_yaw := wrapf(face_yaw + slip, -PI, PI)
	var road := (1.0 - _calm.v) * HEAD_ROAD
	if road > 1e-3:
		var tan: Vector3 = s["tangent"]
		tan.y = 0.0
		if tan.length_squared() > 1e-6:
			tan = tan.normalized()
			if tan.dot(face) > -0.94:
				target_yaw = wrapf(target_yaw + wrapf(atan2(tan.x, tan.z) - target_yaw, -PI, PI) * road, -PI, PI)
	var tau := HEAD_TAU + HEAD_TAU_DRIFT * _drift_amt + HEAD_TAU_CORNER * absf(_corner) + HEAD_TAU_CALM * (1.0 - _calm.v)
	_arm_err.v = wrapf(_arm_yaw - target_yaw, -PI, PI)
	var err := _arm_err.step(0.0, tau, dt)
	var want := wrapf(target_yaw + err, -PI, PI)
	var chassis_err := wrapf(want - face_yaw, -PI, PI)
	if absf(chassis_err) > MAX_LAG:
		want = wrapf(face_yaw + (MAX_LAG if chassis_err > 0.0 else -MAX_LAG), -PI, PI)
		_arm_err.vel *= 0.2
	var step := wrapf(want - _arm_yaw, -PI, PI)
	var lost := absf(wrapf(_arm_yaw - face_yaw, -PI, PI)) > MAX_LAG
	var max_step := (MAX_ARM_RATE_LOST if lost else MAX_ARM_RATE) * dt
	_arm_yaw = wrapf(_arm_yaw + clampf(step, -max_step, max_step), -PI, PI)
	_arm = Vector3(sin(_arm_yaw), 0.0, cos(_arm_yaw))
	_lag.v = wrapf(_lag_yaw - target_yaw, -PI, PI)
	_lag_yaw = wrapf(target_yaw + _lag.step(0.0, HEAD_RATE_TAU, dt), -PI, PI)
	var yaw_rate := clampf(-wrapf(target_yaw - _lag_yaw, -PI, PI) / HEAD_RATE_TAU, -CORNER_RATE_MAX, CORNER_RATE_MAX)
	var right := _arm.cross(Vector3.UP)
	right = right.normalized() if right.length_squared() > 1e-6 else Vector3(1, 0, 0)
	var ahead := (CORNER_LOOK + CORNER_LOOK_SPEED * sp) / maxf(1.0, track.length)
	var ta: Vector3 = track.sample(k.t + ahead)["tangent"]
	ta.y = 0.0
	var bend_raw := clampf(ta.normalized().dot(right), -1.0, 1.0) if ta.length_squared() > 1e-6 else 0.0
	_bend.step(bend_raw, 0.26, dt)
	var tgt := clampf((yaw_rate * speed / CORNER_G_FULL) * CORNER_MEASURED + _bend.v * CORNER_ANTICIPATED * _calm.v, -1.0, 1.0)
	_corner_d.v = _corner
	var next_corner := _corner_d.step(tgt, CORNER_TAU, dt)
	_corner += clampf(next_corner - _corner, -CORNER_MAX_RATE * dt, CORNER_MAX_RATE * dt)
	_bank.step(minf(1.0, absf(float(s["bank"])) / 0.30) * (1.0 - _air.v), 0.30, dt)


func _update_up(s: Dictionary, dt: float) -> void:
	var up := Vector3.UP.lerp(s["normal"], BANK_GAIN * (1.0 - _air.v))
	up = Vector3.UP if up.length_squared() < 1e-6 or up.y < 0.2 else up.normalized()
	var lean := clampf(_corner * CORNER_ROLL + _drift_signed.v * DRIFT_ROLL * (0.6 + 0.4 * _tier.v), -MAX_ROLL, MAX_ROLL)
	if absf(lean) > 1e-4:
		up = up.rotated(_arm, lean)
	var axis := _up.cross(up)
	var sn := axis.length()
	var ang := atan2(sn, clampf(_up.dot(up), -1.0, 1.0))
	if ang > 1e-5 and sn > 1e-6:
		_up = _up.rotated(axis / sn, minf(ang, MAX_ROLL_RATE * dt)).normalized()


func _pose_chase(track: SunsetTrack, k: Kart, kpos: Vector3, sp: float, dt: float) -> void:
	var surge := _surge.step(0.0, BOOST_SURGE_OMEGA, BOOST_SURGE_ZETA, dt)
	var boost := _boost.v * (1.0 - _look.v)
	var pivot := kpos + _up * PIVOT_UP
	var dir := _arm
	if _look.v > 1e-3:
		dir = dir.rotated(_up, PI * _look.v)
	var dist := ARM_DIST + ARM_DIST_SPEED * sp + surge * BOOST_SURGE_DIST - boost * BOOST_DIST \
		- _brake.v * BRAKE_DIST + _drift_amt * DRIFT_DIST - _look.v * 1.4
	var height := ARM_HEIGHT + ARM_HEIGHT_SPEED * sp + surge * BOOST_SURGE_HEIGHT - boost * BOOST_HEIGHT \
		- _brake.v * BRAKE_HEIGHT + _drift_amt * DRIFT_HEIGHT + _air.v * AIR_HEIGHT \
		+ _bank.v * BANK_HEIGHT * (1.0 - _look.v) + _look.v * 0.25
	dist = maxf(2.2, dist)
	height = maxf(0.35, height)
	var want := _sweep_arm(track, k, pivot, dir, dist, height)
	_arm_frac.step(want, ARM_FRAC_IN if want < _arm_frac.v else ARM_FRAC_OUT, dt)
	var f := clampf(_arm_frac.v, 0.18, 1.0)
	_eye = pivot - dir * (dist * f) + _up * (height * f)
	var dip := _dip.step(0.0, 15.0, 0.42, dt)
	var kick_v := _kick.step(0.0, 21.0, 0.36, dt)
	_eye += _up * (dip * 6.0) + dir * (kick_v * 8.0)


func _sweep_arm(track: SunsetTrack, k: Kart, pivot: Vector3, dir: Vector3, dist: float, height: float) -> float:
	var hint := _cam_t if _cam_t >= 0.0 else k.t
	for i in range(1, SWEEP_STATIONS + 1):
		var u := float(i) / SWEEP_STATIONS
		var p := pivot - dir * (dist * u) + _up * (height * u)
		var pr := track.probe(p, hint)
		var clear := GROUND_CLEAR * (0.45 + 0.55 * u)
		if p.y < float(pr["y"]) + clear or not track.collide_walls(p, CAM_RADIUS, hint).is_empty():
			return float(i - 1) / SWEEP_STATIONS
	return 1.0


func _frame_x(dt: float) -> float:
	var want := -FRAME_LAG_CANCEL * wrapf(_arm_yaw - _face_yaw, -PI, PI) - FRAME_BEND * _bend.v * _calm.v - FRAME_DRIFT * _drift_signed.v * _tier.v
	if _look.v > 0.5:
		want = 0.0
	_comp_ang += clampf(want - _comp_ang, -FRAME_ANG_RATE * dt, FRAME_ANG_RATE * dt)
	var tan_h := tan(deg_to_rad(fov) * 0.5) * _aspect()
	return clampf(tan(_comp_ang) / tan_h, -FRAME_X_MAX, FRAME_X_MAX)


func _frame_y(sp: float) -> float:
	return clampf(FRAME_Y + FRAME_Y_SPEED * sp + FRAME_Y_DRIFT * _drift_amt, FRAME_Y_MIN, FRAME_Y_MAX)


func _aspect() -> float:
	var vs := get_viewport().get_visible_rect().size
	return vs.x / vs.y if vs.y > 0.0 else 16.0 / 9.0


func _constrain_eye(track: SunsetTrack, k: Kart, kpos: Vector3, dt: float) -> void:
	if _has_prev_eye:
		var d := _eye - _prev_eye - k.velocity * dt
		var max_step := MAX_EYE_SLIP * dt
		if d.length() > max_step:
			_eye -= d * (1.0 - max_step / d.length())
	_has_prev_eye = true
	var rel := _eye - kpos
	if rel.length() < MIN_RANGE:
		_eye = kpos + (rel.normalized() * MIN_RANGE if rel.length() > 1e-3 else -_arm * MIN_RANGE)
	var under := track.probe(_eye, _cam_t if _cam_t >= 0.0 else k.t)
	var gap := absf(fposmod(float(under["t"]) - k.t + 0.5, 1.0) - 0.5)
	_cam_t = under["t"] if gap < 0.05 else k.t
	if not _ground_init:
		_ground_y = under["y"]
		_ground_init = true
	else:
		_ground_y = clampf(under["y"], _ground_y - 26.0 * dt, _ground_y + 26.0 * dt)
	_eye.y = maxf(_eye.y, _ground_y + GROUND_CLEAR)
	var wall := track.collide_walls(_eye, CAM_RADIUS, _cam_t)
	if not wall.is_empty():
		_eye += wall["push"]
	_prev_eye = _eye


## Aim so the kart sits at (fx, fy) in normalised screen space.
func _frame_subject(kpos: Vector3, fx: float, fy: float) -> void:
	var pt := kpos + _up * SUBJ_UP
	var dir := pt - _eye
	var r := dir.length()
	if r < 1e-3:
		_aim = pt
		return
	dir /= r
	var tan_v := tan(deg_to_rad(fov) * 0.5)
	var tan_h := tan_v * _aspect()
	var right := dir.cross(_up)
	if right.length_squared() < 1e-6:
		_aim = _eye + dir * r
		return
	right = right.normalized()
	var up := right.cross(dir).normalized()
	dir = dir.rotated(up, atan(fx * tan_h))
	right = dir.cross(_up)
	if right.length_squared() > 1e-6:
		dir = dir.rotated(right.normalized(), -atan(fy * tan_v))
	_aim = _eye + dir * r


func _apply_fov(sp: float, dt: float) -> void:
	var tgt := clampf(FOV_BASE + sp * FOV_SPEED + _boost.v * 6.0 + _look.v * 3.0 + absf(_corner) * FOV_CORNER - _brake.v * FOV_BRAKE, 36.0, 70.0)
	fov = _fov.step(tgt, 11.0, 0.62, dt)


func _apply_transform(dt: float) -> void:
	var fwd := (_aim - _eye)
	if fwd.length_squared() < 1e-8:
		return
	var q := Basis.looking_at(fwd.normalized(), _up).get_rotation_quaternion()
	var shake_amt := _step_trauma(dt)
	if shake_amt > 0.0:
		q = q * Quaternion.from_euler(Vector3(_noise(1) * shake_amt * 0.020, _noise(2) * shake_amt * 0.022, _noise(3) * shake_amt * 0.052))
	if _has_prev_quat:
		var ang := _prev_quat.angle_to(q)
		var max_ang := MAX_SLEW * dt
		if ang > max_ang and ang > 1e-6:
			q = _prev_quat.slerp(q, max_ang / ang)
	_prev_quat = q
	_has_prev_quat = true
	var pos := _eye
	if shake_amt > 0.0:
		pos += Basis(q) * Vector3(_noise(4) * shake_amt * 0.16, _noise(5) * shake_amt * 0.14, 0.0)
	global_transform = Transform3D(Basis(q), pos)


func _noise(seed: int) -> float:
	return sin(_time * 27.3 + seed * 4.7) * 0.62 + sin(_time * 44.1 + seed * 11.3) * 0.38


func _step_trauma(dt: float) -> float:
	if _trauma <= 0.0:
		_trauma_decay = 3.3
		return 0.0
	_trauma = maxf(0.0, _trauma - _trauma_decay * dt)
	return _trauma * _trauma


## Pre-race flyover: orbit the player's kart, easing in to the chase pose.
func _pose_intro(dt: float) -> void:
	intro_t -= dt
	var kpos := _kpos()
	var a := intro_t * 0.9
	var orbit := Vector3(sin(a) * 9.0, 3.0 + intro_t * 1.2, cos(a) * 9.0)
	_orbit_pos = _orbit_pos.lerp(kpos + orbit, clampf(dt * 2.5, 0.0, 1.0))
	global_position = _orbit_pos
	look_at(kpos + Vector3.UP * 0.6, Vector3.UP)
	fov = lerpf(fov, 40.0, clampf(dt * 3.0, 0.0, 1.0))
	_fov.v = fov
	if intro_t <= 0.0:
		_ready_flag = false
		_prev_kart = kpos


## Karts right on top of the camera would fill the screen; hide them until they pull away.
func _hide_blockers() -> void:
	var race = target.race
	if race == null:
		return
	var b := target.global_position + Vector3.UP * 0.6
	for k in race.karts:
		if k == target:
			continue
		var p: Vector3 = k.global_position + Vector3.UP * 0.5
		var d := global_position.distance_to(p)
		var seg := b - global_position
		var t := clampf((p - global_position).dot(seg) / seg.length_squared(), 0.0, 1.0)
		var blocks := (global_position + seg * t).distance_to(p) < 1.1 and t < 0.9
		k.set_camera_hidden(d < 2.4 or (blocks and d < 4.0))
