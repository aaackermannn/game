class_name AIController
extends KartController
## Bot driver ported from kart-royale (src/game/AI.ts AIDriver, MIT): follows the
## shared RacingLine with a PID steering controller, shifts lanes to pass karts
## and dodge mines, plans drifts for real corners, makes occasional "mistakes",
## recovers when stuck, and decides when to use items.
## kart-royale's AI steer is negated before it reaches the kart; we do that here.

enum Mistake { NONE, WOBBLE, LATE_BRAKE, NO_DRIFT }

const EDGE_PUSH_KEEP := 1.2
const LANE_REF_HALF := 9.5
const EDGE_PUSH_GAIN := 0.55
const EDGE_PUSH_MAX := 0.85
const DRIFT_MIN_CURV := 0.0072 / F1.TRACK_SCALE
const DRIFT_EXIT_CURV := 0.0048 / F1.TRACK_SCALE
const DRIFT_EDGE_KEEP := 1.0
const DRIFT_INSIDE_FRAC := 0.34
const DRIFT_INSIDE_MIN := 1.7
const DRIFT_INSIDE_MAX := 3.6
const DRIFT_MAX_HOLD := 4.5
const DRIFT_SPEED_FACTOR := 0.88
const DRIFT_FLICK := 0.45
const DRIFT_FLICK_ROOM := 6.0
const DRIFT_MAX_SPEED := 35.0  # m/s (~125 km/h)

var skill := 0.75
var aggression := 0.5
var band := 1.0  # rubber-band speed factor, set by the race each frame
var _prev_err := 0.0
var _i_err := 0.0
var _steer_smooth := 0.0
var _lane := 0.0
var _lane_target := 0.0
var _drift_hold := false
var _drift_cool := 0.0
var _drift_side := 0.0
var _drift_entry := 0.0
var _drift_t := 0.0
var _hold_t := 0.0
var _noise_phase := 0.0
var _noise_rate := 0.0
var _mistake := Mistake.NONE
var _mistake_t := 0.0
var _next_mistake := 0.0
var _item_delay := 0.0
var _last_item := ""
var _stuck_t := 0.0
var _escape_t := 0.0
var _time := 0.0
var _seed := 0


func _init(seed: int, difficulty_skill: float) -> void:
	_seed = seed
	var h0 := _hash01(seed * 7 + 11)
	var h1 := _hash01(seed * 13 + 5)
	skill = clampf(difficulty_skill + (h0 - 0.5) * 0.20, 0.5, 1.0)
	aggression = clampf(0.45 + (h1 - 0.5) * 0.5, 0.1, 1.0)
	_noise_phase = h0 * TAU
	_noise_rate = 0.55 + h1 * 0.5
	_next_mistake = 9.0 + h1 * 18.0


static func _hash01(n: int) -> float:
	var x := ((n ^ 0x9e3779b9) * 0x85ebca6b) & 0xffffffff
	x ^= x >> 13
	x = (x * 0xc2b2ae35) & 0xffffffff
	return float((x ^ (x >> 16)) & 0xffffffff) / 4294967296.0


func update(k: Kart, dt: float) -> void:
	use_item = false
	burst = false
	var race = k.race
	if race == null:
		return
	var line: RacingLine = race.racing_line
	_time += dt
	if _drift_cool > 0.0:
		_drift_cool -= dt
	if _mistake_t > 0.0:
		_mistake_t -= dt
		if _mistake_t <= 0.0:
			_mistake = Mistake.NONE
	else:
		_next_mistake -= dt
		if _next_mistake <= 0.0:
			_roll_mistake()
	if not k.input_enabled:
		steer = 0.0
		throttle = 0.0
		brake = 0.0
		drift = false
		return
	var L := line.length
	var d := k.t * L
	var spd := k.speed
	_update_lane(k, race, line, d, dt)
	var look := clampf(5.5 + absf(spd) * (0.42 + skill * 0.18), 6.0, 60.0)
	var tgt := line.point(d + look)
	var li := line.index(d + look)
	var limit := maxf(0.6, line.half[li] - 1.4)
	var line_off := line.off[li]
	var bias := clampf(line_off + _lane, -limit, limit) - line_off
	tgt += Vector3(line.bx[li], line.by[li], line.bz[li]) * bias
	var pos := k.position_k
	var desired := atan2(tgt.x - pos.x, tgt.z - pos.z)
	var heading := atan2(k.fwd.x, k.fwd.z)
	var err := wrapf(desired - heading, -PI, PI)
	var lat := line.lateral_of(pos, k.t)
	var cross := lat - (line.offset_at(d) + bias)
	var d_err := clampf((err - _prev_err) / maxf(dt, 1e-3), -8.0, 8.0)
	_prev_err = err
	_i_err = clampf(_i_err + err * dt, -0.4, 0.4)
	# Pure pursuit: the curvature that reaches the target point, turned into a
	# steering input through the kart's own steering geometry. Unlike a fixed
	# gain it stays stable at any speed (kart-royale's PID was tuned for 30 m/s).
	var to_tgt := Vector2(tgt.x - pos.x, tgt.z - pos.z)
	var dist := maxf(4.0, to_tgt.length())
	var kappa := 2.0 * sin(err) / dist
	var falloff := 0.32 + 0.68 / (1.0 + absf(spd) * 0.075)
	var pp := atan(kappa * Kart.WHEELBASE) / (Kart.MAX_STEER * falloff)
	var slow := clampf(30.0 / maxf(absf(spd), 1.0), 0.2, 1.0)
	var s := pp * 1.15 + d_err * 0.06 * slow + _i_err * 0.15 * slow + cross * 0.03 * slow
	# Target behind (spun round / facing the wrong way): sin(err) ~ 0 would barely
	# steer, so turn at full lock towards it.
	if absf(err) > PI * 0.5:
		s = signf(err)
	var half_now := line.half[line.index(d)]
	var out_sign := 1.0 if lat >= 0.0 else -1.0
	var excess := absf(lat) - (half_now - EDGE_PUSH_KEEP)
	if excess > 0.0:
		s += out_sign * minf(excess * EDGE_PUSH_GAIN, EDGE_PUSH_MAX)
	if spd < -0.5:
		s = -s
	var n1 := sin(_time * _noise_rate + _noise_phase)
	var n2 := sin(_time * _noise_rate * 2.73 + _noise_phase * 1.7)
	s += (n1 * 0.7 + n2 * 0.3) * 0.075 * (1.25 - skill)
	if _mistake == Mistake.WOBBLE:
		s += sin(_time * 9.5 + _noise_phase) * 0.30
	s = clampf(s, -1.0, 1.0)
	_steer_smooth += (s - _steer_smooth) * minf(1.0, dt * 16.0)
	var cmd_steer := clampf(_steer_smooth, -1.0, 1.0)
	drift = _update_drift(k, line, d, spd, lat, half_now, dt)
	if _drift_entry > 0.0 and k.drift_dir == 0.0:
		var inside_sign := -_drift_side
		var room := half_now - inside_sign * lat
		cmd_steer = clampf(cmd_steer + _drift_side * DRIFT_FLICK * clampf(room / DRIFT_FLICK_ROOM, 0.3, 1.0), -1.0, 1.0)
	var react_span := clampf(absf(spd) * 0.35, 4.0, 45.0)
	var target := minf(line.speed_at(d), line.min_speed(d, react_span))
	target *= band
	target *= 0.90 + skill * 0.11
	var committed := _drift_hold or k.drift_dir != 0.0
	var approaching := not committed and absf(line.peak_curv(d, clampf(absf(spd) * 0.95, 16.0, 110.0))) > DRIFT_MIN_CURV
	if committed or approaching:
		target *= DRIFT_SPEED_FACTOR
	if _mistake == Mistake.LATE_BRAKE:
		target *= 1.16
	if k.spin_time > 0.0:
		target = 0.0
	var over := spd - target
	if over > 2.2:
		brake = clampf((over - 2.2) * 0.22, 0.0, 1.0)
		throttle = 0.0
	elif over > 0.4:
		brake = 0.0
		throttle = clampf(1.0 - over * 0.5, 0.25, 1.0)
	else:
		brake = 0.0
		throttle = 1.0
	if k.drift_dir != 0.0 or k.boost_time > 0.0:
		throttle = 1.0
		brake = 0.0
	if _escape_t > 0.0:
		_escape_t -= dt
		_stuck_t = 0.0
		drift = false
		throttle = 1.0
		brake = 0.0
	else:
		if absf(spd) < 1.6 and k.spin_time <= 0.0:
			_stuck_t += dt
		else:
			_stuck_t = maxf(0.0, _stuck_t - dt * 2.0)
		if _stuck_t > 1.4:
			throttle = 0.0
			brake = 1.0
			drift = false
			cmd_steer = clampf(-err * 1.4, -1.0, 1.0)
			if _stuck_t > 3.0:
				_stuck_t = 0.0
				_escape_t = 1.2
	# kart-royale feeds -cmd.steer to the kart.
	steer = -cmd_steer
	_decide_item(k, race, line, d, dt)
	if k.energy >= 33.0 and absf(line.peak_curv(d, 100.0)) < 0.004 / F1.TRACK_SCALE and k.boost_time <= 0.0 and randf() < dt * 0.5:
		burst = true


func _roll_mistake() -> void:
	var r := _hash01((_seed + 1) * 977 + int(_next_mistake * 1000.0) + 7 + int(_time * 10.0))
	var gap := 10.0 + skill * 26.0
	_next_mistake = gap * (0.55 + r)
	if r > 0.72 - skill * 0.25:
		return
	if r < 0.28:
		_mistake = Mistake.WOBBLE
		_mistake_t = 0.5 + r
	elif r < 0.52:
		_mistake = Mistake.LATE_BRAKE
		_mistake_t = 1.1
	else:
		_mistake = Mistake.NO_DRIFT
		_mistake_t = 1.8


func _update_lane(k: Kart, race, line: RacingLine, d: float, dt: float) -> void:
	var want := 0.0
	var half := line.half[line.index(d)]
	var road_scale := clampf(half / LANE_REF_HALF, 0.55, 1.0)
	var side_window := clampf(half * 0.62, 3.0, 5.5)
	var r := k.fwd.cross(Vector3.UP)
	r = r.normalized() if r.length_squared() > 1e-8 else Vector3(1, 0, 0)
	for o: Kart in race.karts:
		if o == k:
			continue
		var rel := o.position_k - k.position_k
		if absf(rel.y) > 3.0:
			continue
		var ahead := rel.dot(k.fwd)
		if ahead < -2.0 or ahead > 26.0:
			continue
		var side := rel.dot(r)
		if absf(side) > side_window:
			continue
		var prox := 1.0 - clampf(ahead / 26.0, 0.0, 1.0)
		var push := (2.6 + aggression * 1.2) * road_scale * prox * (-1.0 if side > 0.0 else 1.0)
		want += push * (1.0 - absf(side) / side_window)
	for h in race.hazards():
		var hp: Vector3 = h["pos"]
		if h["owner"] == k:
			continue
		var rel := hp - k.position_k
		if absf(rel.y) > 3.0:
			continue
		var ahead := rel.dot(k.fwd)
		if ahead < 0.0 or ahead > 34.0:
			continue
		var side := rel.dot(r)
		var clear: float = h["r"] + 1.5
		if absf(side) > clear + 2.5:
			continue
		var prox := 1.0 - clampf(ahead / 34.0, 0.0, 1.0)
		want += (-1.0 if side > 0.0 else 1.0) * (clear + 1.2 - absf(side)) * prox * 2.2
	if k.place == 1 and aggression > 0.5:
		var c := line.curv_at(d)
		want += (signf(c) if c != 0.0 else 1.0) * 0.6 * aggression
	var drifting := _drift_hold or k.drift_dir != 0.0
	if drifting:
		want += -_drift_side * clampf(half * DRIFT_INSIDE_FRAC, DRIFT_INSIDE_MIN, DRIFT_INSIDE_MAX)
	var lane_max := maxf(0.8, half - 1.4)
	_lane_target = clampf(want, -lane_max, lane_max)
	_lane += (_lane_target - _lane) * minf(1.0, dt * (6.5 if drifting else 2.6))
	if absf(_lane_target) < 0.05:
		_lane *= 1.0 - minf(1.0, dt * 1.6)


func _update_drift(k: Kart, line: RacingLine, d: float, spd: float, lat: float, half: float, dt: float) -> bool:
	# Drifting is a slow-corner technique: at F1 speeds it spins the car, so bots
	# only drift into corners whose racing-line speed is below DRIFT_MAX_SPEED.
	var corner_speed := line.min_speed(d, clampf(absf(spd) * 0.9, 10.0, 110.0))
	if _mistake == Mistake.NO_DRIFT or k.spin_time > 0.0 or spd < 9.0 or (not _drift_hold and corner_speed > DRIFT_MAX_SPEED):
		_end_drift(0.25)
		return false
	var span := clampf(absf(spd) * 0.45, 10.0, 60.0)
	if _drift_hold:
		_drift_t += dt
		var engaged := k.drift_dir != 0.0
		if engaged:
			_drift_entry = 0.0
		else:
			_drift_entry -= dt
		if not engaged and _drift_entry <= 0.0:
			_end_drift(0.6)
			return false
		if absf(lat) > half - DRIFT_EDGE_KEEP:
			_end_drift(0.45)
			return false
		if _drift_t > DRIFT_MAX_HOLD:
			_end_drift(0.5)
			return false
		var opened := absf(line.peak_curv(d, span)) < DRIFT_EXIT_CURV
		var nearly_there := k.drift_level == 0 and k.drift_charge > 0.5
		if opened and not nearly_there:
			_end_drift(0.3)
			return false
		return true
	var peak := line.peak_curv(d, span)
	if _drift_cool <= 0.0 and absf(peak) > DRIFT_MIN_CURV and spd > 12.0 and not k.airborne and k.boost_time <= 0.3:
		_drift_hold = true
		_drift_t = 0.0
		_drift_side = -signf(peak)
		_drift_entry = 0.6
		return true
	return false


func _end_drift(cool: float) -> void:
	_drift_hold = false
	_drift_entry = 0.0
	_drift_t = 0.0
	_drift_cool = maxf(_drift_cool, cool)


## kart-royale decideItem, for Loop GP's names of the same items:
## turbo/turbo3 = boost, bouncer = straight shell, rocket = homing shell,
## mine = slip hazard, rampage = invincibility, zap = lightning, kaboom = bomb.
func _decide_item(k: Kart, race, line: RacingLine, d: float, dt: float) -> void:
	use_backwards = false
	var held := k.item if k.roulette_time <= 0.0 else ""
	if held == "":
		_last_item = ""
		_hold_t = 0.0
		return
	_hold_t += dt
	if held != _last_item:
		_last_item = held
		_hold_t = 0.0
		_item_delay = 0.25 + (1.0 - skill) * 0.7 + _hash01(k.racer_index * 31 + held.length()) * 0.45
	if _item_delay > 0.0:
		_item_delay -= dt
		return
	var ahead_kart: Kart = null
	var ahead_dist := INF
	var behind_dist := INF
	for o: Kart in race.karts:
		if o == k or o.finished:
			continue
		var rel := o.position_k - k.position_k
		var dist := rel.length()
		if dist < 1e-3 or absf(rel.y) > 6.0:
			continue
		var along := rel.dot(k.fwd) / dist
		if along > 0.25 and dist < ahead_dist:
			ahead_dist = dist
			ahead_kart = o
		elif along < -0.2 and dist < behind_dist:
			behind_dist = dist
	var straight := absf(line.peak_curv(d, 100.0)) < 0.011 / F1.TRACK_SCALE
	var leading := k.place == 1
	var fire := false
	var back := false
	var ahead_angle := PI
	if ahead_kart:
		ahead_angle = acos(clampf((ahead_kart.position_k - k.position_k).normalized().dot(k.fwd), -1.0, 1.0))
	match held:
		"turbo", "turbo3":
			fire = k.boost_time <= 0.0 and not k.airborne and (straight or skill < 0.65) and absf(k.speed) > 8.0
			if k.item_count > 1:
				fire = fire or k.surface == SunsetTrack.Surface.OFF_TRACK or k.surface == SunsetTrack.Surface.SAND
		"bouncer":
			if ahead_kart and ahead_dist < 44.0 and ahead_angle < 0.30:
				fire = true
			elif behind_dist < 26.0 or (leading and skill > 0.6):
				fire = true
				back = true
		"rocket":
			if ahead_kart and ahead_dist < 85.0 * F1.TRACK_SCALE:
				fire = true
			elif leading and behind_dist < 22.0:
				fire = true
				back = true
		"mine":
			fire = behind_dist < 60.0 or leading or not straight or aggression > 0.55
			back = behind_dist < 45.0 or leading or skill > 0.5
		"rampage":
			fire = not leading or behind_dist < 30.0 or straight
		"zap":
			fire = not leading
		"kaboom":
			if ahead_kart and ahead_dist < 42.0 and ahead_angle < 0.30:
				fire = true
			elif behind_dist < 20.0:
				fire = true
				back = true
	if not fire and _hold_t > 5.5 + (1.0 - aggression) * 4.5:
		fire = true
		back = held == "mine" or held == "bouncer" or held == "rocket"
	if fire:
		use_item = true
		use_backwards = back
		_last_item = ""
		_hold_t = 0.0
		_item_delay = 0.4
