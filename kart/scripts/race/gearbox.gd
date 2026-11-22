class_name Gearbox
extends RefCounted
## Engine + 8-speed sequential gearbox, modelled on a Formula 1 drivetrain.
##
## Gear spacing follows a real F1 car (speeds at the limiter in each gear, as a
## share of the top-gear speed: 95/135/170/200/235/265/295/330 km/h): a short
## first gear, then progressively closer ratios.
##
## The drive force is real torque through the gearbox: engine torque at the
## current rpm times the gear ratio. A low gear multiplies torque, a high gear
## doesn't, and an engine lugging far below its power band makes little torque,
## so skipping gears at low speed leaves the kart crawling: you have to build
## speed through each gear. Shifts are seamless (torque dips ~40 ms), there's
## a hard rev limiter at 15 000 rpm, and downshifts that would over-rev the engine
## are held and taken as soon as the revs allow.

const GEARS := 8
const IDLE_RPM := 4000.0
const LIMIT_RPM := 15000.0
const RED_RPM := 13500.0
const AUTO_UP_RPM := 13800.0
const AUTO_DOWN_RPM := 9200.0
## F1 gear speeds (km/h at the limiter), scaled to our top gear.
const F1_GEAR_KMH := [100.0, 140.0, 175.0, 210.0, 245.0, 280.0, 315.0, 350.0]
## Top-gear speed at the limiter. Base top speed is 30 m/s, so boosts (up to
## ~1.36x) still have room in 8th before the limiter cuts in.
const TOP_GEAR_SPEED := 350.0 / 3.6
const UPSHIFT_TIME := 0.04
const DOWNSHIFT_TIME := 0.06
const SHIFT_COOLDOWN := 0.18
const SHIFT_TORQUE := 0.35
const DOWNSHIFT_HOLD := 1.2         # a refused downshift waits this long for the revs to drop
## Torque scale: in 1st the drive force is capped by the tyres anyway; in the
## middle gears this keeps the pace close to kart-royale's original drive curve.
const DRIVE_GAIN := 2.2
const DRIVE_CAP := 0.8          # traction limit: F1 0-100 km/h in ~2.6 s
## "Perfect shift" window: an upshift with the shift lights full, just before
## the limiter, rewards the driver (manual gearbox only).
const PERFECT_LO := 13300.0
const PERFECT_HI := 14900.0
const ENGINE_BRAKE_BASE := 0.04
const ENGINE_BRAKE_GAIN := 0.30

var gear := 1                      # 1..8, 0 = reverse
var rpm := IDLE_RPM
var on_limiter := false
var manual := false
var shift_point := AUTO_UP_RPM
var pending_down := false          # a held downshift (HUD can show it)
## Engine braking force (fraction of MAX_DRIVE) while off the throttle: grows with
## revs and with lower gears, so downshifting into a corner slows the car.
var engine_brake := 0.0
var events: Array[String] = []

var _shift_t := 0.0
var _cooldown := 0.0
var _limiter_t := 0.0
var _bounce_t := 0.0
var _last_throttle := 0.0
var _pop_cool := 0.0
var _pending_t := 0.0


static func gear_top_speed(g: int) -> float:
	var i := clampi(g, 1, GEARS) - 1
	return TOP_GEAR_SPEED * float(F1_GEAR_KMH[i]) / float(F1_GEAR_KMH[GEARS - 1])


## Gear ratio relative to 1st (1st = 1.0, taller gears < 1).
static func ratio(g: int) -> float:
	return gear_top_speed(1) / gear_top_speed(g)


static func wheel_rpm(speed: float, g: int) -> float:
	return absf(speed) / gear_top_speed(g) * LIMIT_RPM


## Normalised engine torque curve: weak when lugging, flat 10.5-13k, easing off
## towards the limiter.
static func torque_at(r: float) -> float:
	if r < 10500.0:
		return lerpf(0.28, 1.0, smoothstep(IDLE_RPM, 10500.0, r))
	if r < 13000.0:
		return 1.0
	return lerpf(1.0, 0.85, clampf((r - 13000.0) / 2000.0, 0.0, 1.0))


func take_events() -> Array[String]:
	var e := events
	events = []
	return e


func reset() -> void:
	gear = 1
	rpm = IDLE_RPM
	on_limiter = false
	pending_down = false
	_shift_t = 0.0
	_cooldown = 0.0
	events.clear()


func shift_up() -> void:
	pending_down = false
	if gear >= GEARS or _cooldown > 0.0:
		return
	var was_rpm := rpm
	gear = maxi(gear, 0) + 1
	_shift_t = UPSHIFT_TIME
	_cooldown = SHIFT_COOLDOWN
	events.append("up")
	if manual and _last_throttle > 0.6 and was_rpm >= PERFECT_LO and was_rpm <= PERFECT_HI:
		events.append("perfect")
	if _last_throttle > 0.6 and rpm > 11500.0:
		events.append("backfire")


## Request a downshift. If it would over-rev the engine it is held (like an F1
## gearbox) and taken as soon as the revs allow, within DOWNSHIFT_HOLD seconds.
func shift_down(speed: float) -> void:
	if gear <= 1:
		return
	if _cooldown > 0.0 or wheel_rpm(speed, gear - 1) > LIMIT_RPM:
		pending_down = true
		_pending_t = DOWNSHIFT_HOLD
		return
	_do_down()


func _do_down() -> void:
	gear -= 1
	pending_down = false
	_shift_t = DOWNSHIFT_TIME
	_cooldown = SHIFT_COOLDOWN
	events.append("down")
	events.append("blip")  # auto rev-match


## Advances the engine one step. Returns the drive-force multiplier relative to
## kart-royale's MAX_DRIVE (before throttle).
func update(dt: float, speed: float, throttle: float, brake: float, reversing: bool) -> float:
	_shift_t = maxf(0.0, _shift_t - dt)
	_cooldown = maxf(0.0, _cooldown - dt)
	_pop_cool = maxf(0.0, _pop_cool - dt)
	if reversing:
		gear = 0
		pending_down = false
		rpm = lerpf(rpm, IDLE_RPM + absf(speed) / 8.0 * 6000.0, minf(1.0, dt * 12.0))
		on_limiter = false
		_last_throttle = throttle
		return 1.0
	if gear == 0:
		gear = 1
	if pending_down:
		_pending_t -= dt
		if _pending_t <= 0.0 or gear <= 1:
			pending_down = false
		elif _cooldown <= 0.0 and wheel_rpm(speed, gear - 1) <= LIMIT_RPM:
			_do_down()
	if not manual:
		_auto_shift(speed, throttle, brake)
	# Engine speed follows the wheels. Below ~idle the clutch slips, so the
	# engine can rev up on the throttle to launch, in any gear.
	var target := wheel_rpm(speed, gear)
	if gear <= 2 and target < IDLE_RPM + 1500.0:
		target = maxf(target, IDLE_RPM + throttle * (5000.0 if gear == 1 else 2500.0))
	target = maxf(target, IDLE_RPM)
	var raw := wheel_rpm(speed, gear)
	rpm = lerpf(rpm, minf(target, LIMIT_RPM), minf(1.0, dt * (30.0 if _shift_t > 0.0 else 18.0)))
	# Torque through the gearbox.
	var mult := minf(DRIVE_CAP, DRIVE_GAIN * torque_at(rpm) * ratio(gear))
	# Rev limiter: fuel cut at 15 000 rpm.
	var was := on_limiter
	on_limiter = raw >= LIMIT_RPM - 50.0 and throttle > 0.1
	if on_limiter:
		mult *= clampf((LIMIT_RPM + 250.0 - raw) / 300.0, 0.0, 1.0)
		_limiter_t += dt
		_bounce_t += dt
		rpm = LIMIT_RPM - 380.0 * absf(sin(_bounce_t * 62.0))
		if not was or _limiter_t > 0.3:
			_limiter_t = 0.0
			events.append("limiter")
		if _pop_cool <= 0.0 and randf() < dt * 7.0:
			_pop_cool = 0.09
			events.append("backfire")
	else:
		_limiter_t = 0.0
	if _last_throttle > 0.7 and throttle < 0.2 and rpm > 11000.0 and _pop_cool <= 0.0:
		_pop_cool = 0.15
		events.append("backfire")
	_last_throttle = throttle
	if _shift_t > 0.0:
		mult *= SHIFT_TORQUE
	var rev_frac := clampf((rpm - IDLE_RPM) / (LIMIT_RPM - IDLE_RPM), 0.0, 1.0)
	engine_brake = ENGINE_BRAKE_BASE + ENGINE_BRAKE_GAIN * rev_frac * ratio(gear)
	return mult


func _auto_shift(speed: float, throttle: float, brake: float) -> void:
	var r := wheel_rpm(speed, gear)
	if throttle > 0.2 and r >= shift_point and gear < GEARS:
		shift_up()
	elif gear > 1 and (r < AUTO_DOWN_RPM or (brake > 0.3 and r < AUTO_DOWN_RPM + 1500.0)):
		if wheel_rpm(speed, gear - 1) <= AUTO_UP_RPM:
			shift_down(speed)
