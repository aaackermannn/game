class_name NetSim
## Deterministic kart movement for NET LAB — the Godot counterpart of
## Unreal's UCharacterMovementComponent::PerformMovement().
##
## The SAME function `step()` runs:
##   * on the owning client, to predict its own kart immediately (CSP);
##   * on the server, to compute the authoritative result from the client's input;
##   * on the owning client again, to replay unacknowledged inputs after a
##     server correction (reconciliation).
## It only reads `Input` (intent: throttle, steer, dash flag) and `State`, never a
## position sent by a client — so a client cannot teleport itself.

const TICK_RATE := 60
const DT := 1.0 / TICK_RATE

# --- movement tuning ----------------------------------------------------------
const MAX_SPEED := 16.0
const MAX_REVERSE := 6.0
const ACCEL := 20.0
const BRAKE := 34.0
const COAST_DRAG := 6.0
const TURN_RATE := 2.6          # rad/s at full steer and speed >= TURN_FULL_SPEED
const TURN_FULL_SPEED := 6.0
const KART_RADIUS := 1.1

# --- the latency-sensitive action: DASH ---------------------------------------
const DASH_SPEED := 34.0        # m/s during the burst
const DASH_TICKS := 12          # 0.2 s burst
const DASH_COOLDOWN_TICKS := 90 # 1.5 s between dashes
const DASH_MIN_SPEED := 3.0     # must already be rolling forward

# --- arena --------------------------------------------------------------------
const ARENA_HALF := Vector2(34.0, 24.0)
## Solid pillars (x, z, half-width, half-depth). Dashing into them is the
## "dash next to an obstacle" scenario from the assignment.
const PILLARS := [
	Vector4(-12.0, -6.0, 2.5, 2.5),
	Vector4(12.0, 6.0, 2.5, 2.5),
	Vector4(0.0, 14.0, 7.0, 1.2),
	Vector4(0.0, -14.0, 7.0, 1.2),
]

## Reasons the server rejects a dash request.
enum DashReject { OK, COOLDOWN, ALREADY_DASHING, TOO_SLOW }
const REJECT_NAMES := ["ok", "cooldown", "already_dashing", "too_slow"]


class Cmd:
	var seq := 0            # sequence number of this input (one per tick)
	var throttle := 0.0     # -1 .. 1
	var steer := 0.0        # -1 .. 1 (positive = left)
	var dash := false       # "I want to dash on this tick"

	func to_array() -> Array:
		return [seq, throttle, steer, dash]

	static func from_array(a: Array) -> Cmd:
		var i := Cmd.new()
		i.seq = int(a[0])
		# Server-side sanitising: never trust ranges coming from the network.
		var th := float(a[1])
		var st := float(a[2])
		i.throttle = 0.0 if is_nan(th) else clampf(th, -1.0, 1.0)
		i.steer = 0.0 if is_nan(st) else clampf(st, -1.0, 1.0)
		i.dash = bool(a[3])
		return i


class State:
	var pos := Vector2.ZERO   # (x, z) on the ground plane
	var heading := 0.0        # yaw, radians; forward = (-sin, -cos)
	var speed := 0.0          # signed forward speed, m/s
	var dash_ticks := 0       # >0 while the dash burst is active
	var cooldown_ticks := 0   # >0 while the dash is on cooldown

	func copy() -> State:
		var s := State.new()
		s.pos = pos
		s.heading = heading
		s.speed = speed
		s.dash_ticks = dash_ticks
		s.cooldown_ticks = cooldown_ticks
		return s

	func to_array() -> Array:
		return [pos, heading, speed, dash_ticks, cooldown_ticks]

	static func from_array(a: Array) -> State:
		var s := State.new()
		s.pos = a[0]
		s.heading = float(a[1])
		s.speed = float(a[2])
		s.dash_ticks = int(a[3])
		s.cooldown_ticks = int(a[4])
		return s

	func forward() -> Vector2:
		return Vector2(-sin(heading), -cos(heading))

	## How far apart two states are, for the reconciliation threshold.
	func error_to(o: State) -> float:
		var e := pos.distance_to(o.pos)
		e += absf(angle_difference(heading, o.heading)) * 2.0
		e += absf(speed - o.speed) * 0.05
		if dash_ticks != o.dash_ticks or cooldown_ticks != o.cooldown_ticks:
			e += 1.0
		return e


## Server-side rule check for the dash (also used by an honest client to
## predict whether the server will accept it).
static func dash_check(s: State) -> int:
	if s.dash_ticks > 0:
		return DashReject.ALREADY_DASHING
	if s.cooldown_ticks > 0:
		return DashReject.COOLDOWN
	if s.speed < DASH_MIN_SPEED:
		return DashReject.TOO_SLOW
	return DashReject.OK


## Advance `s` by one tick using input `i`. Returns the dash verdict
## (DashReject.OK if no dash was requested). `cheat_ignore_cooldown` and
## `speed_mult` exist only so the client can deliberately diverge from the
## server for the reconciliation demo — the server always calls with defaults.
static func step(s: State, i: Cmd, cheat_ignore_cooldown := false, speed_mult := 1.0) -> int:
	var verdict := DashReject.OK
	if i.dash:
		verdict = dash_check(s)
		if cheat_ignore_cooldown and verdict == DashReject.COOLDOWN:
			verdict = DashReject.OK
		if verdict == DashReject.OK:
			s.dash_ticks = DASH_TICKS
			s.cooldown_ticks = DASH_COOLDOWN_TICKS

	if s.cooldown_ticks > 0:
		s.cooldown_ticks -= 1

	# Steering: turning needs speed, reversing flips the wheel.
	var turn_k := clampf(s.speed / TURN_FULL_SPEED, -1.0, 1.0)
	var turn_scale := 0.55 if s.dash_ticks > 0 else 1.0
	s.heading = wrapf(s.heading + i.steer * TURN_RATE * turn_k * turn_scale * DT, -PI, PI)

	var top := MAX_SPEED * speed_mult
	if s.dash_ticks > 0:
		s.dash_ticks -= 1
		s.speed = DASH_SPEED * speed_mult
		if s.dash_ticks == 0:
			s.speed = top
	elif i.throttle > 0.0:
		if s.speed < 0.0:
			s.speed = minf(s.speed + BRAKE * DT, 0.0)
		else:
			s.speed = minf(s.speed + ACCEL * speed_mult * i.throttle * DT, top)
	elif i.throttle < 0.0:
		if s.speed > 0.0:
			s.speed = maxf(s.speed - BRAKE * DT, 0.0)
		else:
			s.speed = maxf(s.speed - ACCEL * 0.6 * -i.throttle * DT, -MAX_REVERSE)
	else:
		s.speed = move_toward(s.speed, 0.0, COAST_DRAG * DT)

	s.pos += s.forward() * s.speed * DT
	_collide(s)
	return verdict


## Push the kart (a circle) out of walls and pillars and kill the speed that
## points into the obstacle.
static func _collide(s: State) -> void:
	var hit := false
	var lim := ARENA_HALF - Vector2(KART_RADIUS, KART_RADIUS)
	if absf(s.pos.x) > lim.x or absf(s.pos.y) > lim.y:
		s.pos = s.pos.clamp(-lim, lim)
		hit = true
	for p: Vector4 in PILLARS:
		var c := Vector2(p.x, p.y)
		var half := Vector2(p.z, p.w)
		var closest := (s.pos - c).clamp(-half, half) + c
		var d := s.pos - closest
		var dist := d.length()
		if dist < KART_RADIUS:
			var n := d / dist if dist > 0.0001 else Vector2(0, 1)
			s.pos = closest + n * KART_RADIUS
			hit = true
	if hit:
		s.speed *= 0.35
		if s.dash_ticks > 0:
			s.dash_ticks = 0  # a dash ends when you slam into something


static func spawn_state(slot: int) -> State:
	var s := State.new()
	var spots := [Vector2(-24, 16), Vector2(24, -16), Vector2(-24, -16), Vector2(24, 16)]
	s.pos = spots[slot % spots.size()]
	s.heading = PI if s.pos.y < 0 else 0.0
	return s
