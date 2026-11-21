class_name Items
## Item system ported from kart-royale (src/game/Items.ts + Projectiles.ts, MIT):
## position-weighted roll, and projectiles that follow the road. Loop GP keeps its
## own comic names and looks:
##   turbo   / turbo3  - boost (x1 / x3)
##   bouncer - straight ball, bounces off walls (up to 4), spins the kart it hits
##   rocket  - homes along the racing line onto the kart ahead, pops on walls
##   mine    - ink mine: lobbed ahead or dropped behind, lies on the road
##   rampage - invincible for a while, rams rivals aside
##   zap     - squashes and shrinks every rival
##   kaboom  - lobbed bomb, blast radius with falloff

const ALL := ["turbo", "turbo3", "bouncer", "rocket", "mine", "rampage", "zap", "kaboom"]
const LABELS := {
	"turbo": "TURBO", "turbo3": "TRIPLE TURBO", "bouncer": "BOUNCER", "rocket": "ROCKET",
	"mine": "INK MINE", "rampage": "RAMPAGE", "zap": "ZAP!", "kaboom": "KABOOM",
}
## kart-royale WEIGHTS: [leader, mid-pack, last].
const WEIGHTS := {
	"turbo": [10, 26, 16], "turbo3": [0, 10, 21], "bouncer": [33, 19, 6], "rocket": [4, 21, 17],
	"mine": [38, 13, 4], "rampage": [0, 4, 17], "zap": [0, 2, 10], "kaboom": [15, 11, 5],
}
const TURBO_TIME := 1.55
const TURBO_STRENGTH := 1.3
const RAMPAGE_TIME := 7.4
const ZAP_TIME := 6.5
const ZAP_STUN := 0.65
const SHELL_R := 0.42
const BOUNCER_SPEED := 33.0
const ROCKET_SPEED := 37.0
const BOMB_GRAVITY := 21.0
const MAX_BOUNCES := 4
const BLAST_RADIUS := 8.2


static func roll(place: int, racers: int) -> String:
	var p := clampf(float(place - 1) / maxf(racers - 1, 1), 0.0, 1.0)
	var total := 0.0
	var pick := "turbo"
	for kind in ALL:
		var w: Array = WEIGHTS[kind]
		var v: float = lerpf(w[0], w[1], p * 2.0) if p < 0.5 else lerpf(w[1], w[2], (p - 0.5) * 2.0)
		if v <= 0.0:
			continue
		total += v
		if randf() * total < v:
			pick = kind
	return pick


## One live projectile (kart-royale Proj in state Live).
class Projectile:
	extends Node3D
	var kind := ""
	var owner_kart: Kart
	var owner_lock := 0.0
	var vel := Vector3.ZERO
	var life := 9.0
	var bounces := 0
	var hint_t := 0.0
	var target: Kart
	var homing := false
	var alive := true
	var radius := 1.4      # hazard radius for the AI
	var _spin := 0.0
	var _visual: Node3D

	func setup(k: String, from: Kart, backwards: bool, tgt: Kart) -> void:
		kind = k
		owner_kart = from
		target = tgt
		homing = kind == "rocket"
		hint_t = from.t
		radius = 1.1 if kind == "mine" else 1.4
		owner_lock = 0.55 if backwards else (1.15 if kind == "kaboom" else (1.7 if kind == "mine" else 0.25))
		var sign := -1.0 if backwards else 1.0
		var dir := from.fwd
		dir.y = 0.0
		dir = dir.normalized() if dir.length_squared() > 1e-6 else Vector3(0, 0, 1)
		position = from.position_k + dir * (sign * 1.35) + Vector3.UP * 0.35
		var flat_vel := from.velocity
		flat_vel.y = 0.0
		match kind:
			"mine":
				life = 55.0
				vel = Vector3(0, 0.5 if backwards else 5.5, 0)
				if backwards:
					vel += from.velocity * 0.15
				else:
					vel += flat_vel + dir * 12.0
			"kaboom":
				life = 2.7
				vel = dir * (sign * 19.0) + Vector3.UP * 9.5 + from.velocity * 0.55
			"rocket":
				life = 12.0
				vel = dir * (sign * ROCKET_SPEED)
			_:
				life = 9.0
				vel = dir * (sign * BOUNCER_SPEED) + (from.velocity * 0.35 if sign > 0.0 else Vector3.ZERO)
		_visual = Props.make(_model_name())
		add_child(_visual)
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON

	func _model_name() -> String:
		match kind:
			"rocket":
				return "rocket"
			"mine":
				return "mine"
			"kaboom":
				return "kaboom"
		return "bouncer"

	func ground_gap() -> float:
		return 0.14 if kind == "mine" else SHELL_R * 0.75

	## kart-royale stepLive. Returns false when the projectile is used up.
	func tick(dt: float, race) -> bool:
		var track: SunsetTrack = race.track
		var line: RacingLine = race.racing_line
		if owner_lock > 0.0:
			owner_lock -= dt
		life -= dt
		if life <= 0.0:
			if kind == "kaboom":
				race.explode(self, 1.0)
			return false
		if kind == "kaboom":
			vel.y -= BOMB_GRAVITY * dt
		elif homing:
			_steer_homing(race, line, dt)
		position += vel * dt
		var pr := track.probe(position, hint_t)
		hint_t = pr["t"]
		var floor_y: float = float(pr["y"]) + ground_gap()
		if kind == "mine":
			if position.y > floor_y:
				vel.y -= BOMB_GRAVITY * dt
				_curve_with_road(line, dt)
			if position.y <= floor_y:
				position.y = floor_y
				vel = Vector3.ZERO
			if pr["surface"] == SunsetTrack.Surface.WATER:
				return false
		elif kind == "kaboom":
			if position.y <= floor_y:
				race.explode(self, 1.0)
				return false
		else:
			position.y += (floor_y - position.y) * minf(1.0, dt * 14.0)
			vel.y = 0.0
			if pr["surface"] == SunsetTrack.Surface.WATER or float(pr["edge_ratio"]) > 3.2:
				return false
		if kind != "mine":
			var hit := track.collide_walls(position, SHELL_R + 0.15, hint_t)
			if not hit.is_empty():
				position += hit["push"]
				var n: Vector3 = hit["normal"]
				var vn := vel.dot(n)
				if vn < 0.0:
					vel += n * (-2.0 * vn)
					vel *= 0.94
					bounces += 1
					# Nudge the bounce down the road, as kart-royale does.
					var along := line.point(hint_t * line.length + 2.0) - line.point(hint_t * line.length)
					along.y = 0.0
					if along.length_squared() > 1e-6:
						var sp := vel.length()
						vel += along.normalized() * (sp * 0.18 * signf(vel.dot(along) if vel.dot(along) != 0.0 else 1.0))
						vel = vel.normalized() * sp
					if kind == "rocket" or bounces > MAX_BOUNCES:
						race.explode(self, 0.5)
						return false
		_orient(dt)
		return _test_karts(race)

	func _curve_with_road(line: RacingLine, dt: float) -> void:
		var flat := Vector2(vel.x, vel.z)
		var speed := flat.length()
		if speed < 1e-3:
			return
		var aim := line.point(hint_t * line.length + maxf(8.0, speed * 0.5))
		var dir := Vector2(aim.x - position.x, aim.z - position.z)
		if dir.length_squared() < 1e-6:
			return
		dir = dir.normalized()
		var turn := minf(1.0, dt * 3.2)
		flat += (dir * speed - flat) * turn
		flat = flat.normalized() * speed
		vel.x = flat.x
		vel.z = flat.y

	func _steer_homing(race, line: RacingLine, dt: float) -> void:
		if target and (target.finished or target.position_k.distance_to(position) > 115.0):
			target = null
		var aim: Vector3
		var dist := target.position_k.distance_to(position) if target else INF
		var my_d := hint_t * line.length
		if target and dist < 16.0 and (target.position_k - position).dot(vel) > 0.0:
			aim = target.position_k + Vector3.UP * 0.3
		else:
			var look := 9.0 + minf(14.0, (dist if target else 45.0) * 0.2)
			aim = line.point(my_d + look)
			var li := line.index(my_d + look)
			var my_lat := line.lateral_of(position, hint_t)
			var t_lat: float = line.lateral_of(target.position_k, target.t) if target else line.off[li]
			var want := my_lat + (t_lat - my_lat) * 0.6 - line.off[li]
			var lim := maxf(0.5, line.half[li] - 0.8)
			var bias := clampf(line.off[li] + want, -lim, lim) - line.off[li]
			aim += Vector3(line.bx[li], line.by[li], line.bz[li]) * bias
		var dir := (aim - position).normalized()
		var turn := minf(1.0, dt * 5.5)
		vel.x += (dir.x * ROCKET_SPEED - vel.x) * turn
		vel.z += (dir.z * ROCKET_SPEED - vel.z) * turn
		vel.y = 0.0
		var flat := Vector2(vel.x, vel.z)
		flat = flat.normalized() * ROCKET_SPEED if flat.length() > 1e-6 else Vector2(0, ROCKET_SPEED)
		vel.x = flat.x
		vel.z = flat.y

	func _test_karts(race) -> bool:
		var reach := (0.55 if kind == "mine" else SHELL_R) + 1.0
		for k: Kart in race.karts:
			if k == owner_kart and owner_lock > 0.0:
				continue
			var d := k.position_k - position
			if absf(d.y) > 1.8:
				continue
			d.y = 0.0
			if d.length_squared() > reach * reach:
				continue
			if k.star_time > 0.0:
				race.popup("BLOCKED!", position + Vector3.UP * 1.6, Game.CYAN)
				return false
			if k.spin_time > 0.9:
				continue
			if kind == "kaboom":
				race.explode(self, 1.0)
				return false
			if k.take_hit(1.15 if kind == "mine" else 1.5):
				race.on_item_hit(k, kind, position)
			return false
		return true

	func _orient(dt: float) -> void:
		_spin += dt * (14.0 if kind == "bouncer" else 3.0)
		var flat := Vector3(vel.x, 0.0, vel.z)
		if kind == "rocket" and flat.length_squared() > 1e-4:
			_visual.basis = Basis.looking_at(flat.normalized(), Vector3.UP).rotated(flat.normalized(), _spin)
		elif kind == "bouncer":
			_visual.rotation = Vector3(_spin, _spin * 0.6, 0.0)
		else:
			_visual.rotation.y = _spin
