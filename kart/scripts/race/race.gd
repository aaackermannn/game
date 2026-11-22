class_name Race
extends Node3D
## Race manager: builds the world, spawns karts, runs countdown, laps,
## placings, pickups, items, bumping, respawns and the finish.

signal race_finished

enum Phase { INTRO, COUNTDOWN, RACING, FINISHED }

var track: Track
var karts: Array[Kart] = []
var player: Kart
var camera: ChaseCamera
var hud: Hud
var phase := Phase.INTRO
var race_time := 0.0
var countdown := 0.0
var projectiles: Array = []
var racing_line: RacingLine

var _boxes: Array[Dictionary] = []   # {node, pos, respawn}
var _orbs: Array[Dictionary] = []
var _post_finish := 0.0
var _last_count := 4
var _overlap_test := "--overlap-test" in OS.get_cmdline_user_args()
var _worst_overlap := 0.0
var _overlap_ticks := 0
var _ticks := 0
var _item_stats := {}  # test log: uses / hits per item
var _prog_prev := {}


func _ready() -> void:
	_build_environment()
	track = SunsetTrack.new()
	track.name = "Track"
	add_child(track)
	track.build()
	racing_line = RacingLine.new()
	racing_line.build(track)
	_spawn_pickups()
	_spawn_karts()
	camera = ChaseCamera.new()
	camera.target = player
	camera.far = 6000.0
	add_child(camera)
	camera.add_child(Toon.ink_overlay())
	camera.make_current()
	camera.snap()
	camera.intro_t = 2.6
	hud = Hud.new()
	hud.race = self
	add_child(hud)
	phase = Phase.INTRO


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky.gdshader")
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.6, 0.75)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.88, 1.0)
	env.fog_density = 0.0012
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 35, 0)
	sun.light_energy = 1.25
	sun.light_color = Color(1.0, 0.97, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	sun.shadow_bias = 0.05
	add_child(sun)


func _spawn_karts() -> void:
	var count := 1 + Game.bot_count
	var bots := []
	for i in Game.ROSTER.size():
		if i != Game.player_racer:
			bots.append(i)
	bots.shuffle()
	var base_skill: float = [0.6, 0.72, 0.86][Game.difficulty]
	var bot_speed: float = [0.93, 0.98, 1.0][Game.difficulty]
	# Player starts at the back half of the grid, like a proper underdog.
	var player_slot := mini(count - 1, maxi(0, count / 2 + 1))
	var b := 0
	for slot in count:
		var k := Kart.new()
		var is_player := slot == player_slot
		var idx: int = Game.player_racer if is_player else bots[b % bots.size()]
		if not is_player:
			b += 1
		var ctrl: KartController
		if is_player and not "--autoplay" in OS.get_cmdline_user_args():
			ctrl = PlayerController.new()
		else:
			ctrl = AIController.new(slot + 1, base_skill)
		k.name = "Kart_%s" % Game.ROSTER[idx]["name"].replace(" ", "")
		k.race = self
		add_child(k)
		k.setup(idx, Game.ROSTER[idx], ctrl, is_player)
		k.place_at(track.grid_transform(slot))
		k.speed_mult = 1.0 if is_player else bot_speed
		k.lap = 0
		k.track_offset = track.closest_offset(k.global_position)
		k.hit_taken.connect(_on_hit)
		k.bumped.connect(_on_bumped)
		karts.append(k)
		if is_player:
			player = k


func _spawn_pickups() -> void:
	for p in track.item_box_spots:
		var n := _make_item_box()
		n.position = p
		add_child(n)
		_boxes.append({"node": n, "pos": p, "respawn": 0.0})
	for p in track.energy_spots:
		var n := _make_orb()
		n.position = p
		add_child(n)
		_orbs.append({"node": n, "pos": p, "respawn": 0.0})


func _make_item_box() -> Node3D:
	var root := Node3D.new()
	var box := Props.make("item_box")
	root.add_child(box)
	var q := Label3D.new()
	q.text = "?"
	q.font = Game.FONT_TITLE
	q.font_size = 120
	q.pixel_size = 0.008
	q.outline_size = 28
	q.outline_modulate = Game.INK
	q.modulate = Game.RED
	q.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	q.position.y = 0.05
	q.render_priority = 2
	root.add_child(q)
	return root


func _make_orb() -> Node3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.38
	m.height = 0.76
	m.radial_segments = 12
	m.rings = 6
	mi.mesh = m
	mi.material_override = Toon.mat(Game.CYAN, true, Color(0.1, 0.5, 0.55))
	return mi


# --- Main loop -----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	match phase:
		Phase.INTRO:
			if camera.intro_t <= 0.0:
				phase = Phase.COUNTDOWN
				countdown = 3.0
				_last_count = 4
		Phase.COUNTDOWN:
			countdown -= delta
			var c := int(ceil(countdown))
			if c != _last_count and c > 0:
				_last_count = c
				hud.flash_big(str(c), Game.YELLOW)
				Game.sfx("countdown_tick")
			if countdown <= 0.0:
				phase = Phase.RACING
				hud.flash_big("GO!", Game.GREEN)
				Game.sfx("countdown_go")
				for k in karts:
					k.input_enabled = true
					k.lap_start_time = 0.0
					# Rocket start: holding throttle exactly at GO pays off.
					if k.is_player and Input.is_action_pressed("accelerate"):
						k.start_boost(0.8, 1.25)
					elif not k.is_player and randf() < 0.4:
						k.start_boost(0.6, 1.2)
		Phase.RACING, Phase.FINISHED:
			race_time += delta
	_update_progress(delta)
	_update_places()
	_update_pickups(delta)
	_update_projectiles(delta)
	if _overlap_test:
		_measure_overlap()
	_rubber_band(delta)
	if phase == Phase.FINISHED:
		_post_finish += delta
		if _post_finish > 4.0 and not hud.results_visible():
			_finish_everyone()
			hud.show_results()


func _update_progress(delta: float) -> void:
	for k in karts:
		var prev := k.track_offset
		var o := track.closest_offset(k.global_position)
		var d := o - prev
		if d < -track.length * 0.5:
			_cross_line(k)
		elif d > track.length * 0.5:
			k.lap -= 1  # reversed over the line
		k.track_offset = o
		k.total_progress = k.lap * track.length + o
		# Wrong-way detection.
		if k.speed > 4.0 and k.forward().dot(track.forward_at(o)) < -0.35:
			k.wrong_way_time += delta
		else:
			k.wrong_way_time = 0.0
		# Out of bounds (into the sea) → respawn on track.
		if track.is_out_of_bounds(k.global_position, o):
			k.respawn()


func _cross_line(k: Kart) -> void:
	k.lap += 1
	if k.lap <= 1:
		k.lap_start_time = race_time
		return
	var lap_time := race_time - k.lap_start_time
	k.lap_start_time = race_time
	if k.best_lap < 0.0 or lap_time < k.best_lap:
		k.best_lap = lap_time
	if k.lap > Game.laps and not k.finished:
		k.finished = true
		k.finish_time = race_time
		k.speed_mult = 0.8
		if k == player:
			phase = Phase.FINISHED
			_post_finish = 0.0
			hud.flash_big("FINISH!", Game.YELLOW, 2.5)
			Game.sfx("finish")
		return
	if k == player:
		if k.lap == Game.laps:
			hud.flash_big("FINAL LAP!", Game.RED, 1.6)
			Game.sfx("final_lap")
		else:
			hud.flash_big("LAP %d" % k.lap, Game.YELLOW, 1.2)
			Game.sfx("lap")


func _update_places() -> void:
	var order := karts.duplicate()
	order.sort_custom(func(a: Kart, b: Kart) -> bool:
		if a.finished and b.finished:
			return a.finish_time < b.finish_time
		if a.finished != b.finished:
			return a.finished
		return a.total_progress > b.total_progress)
	for i in order.size():
		order[i].place = i + 1


func ordered_karts() -> Array:
	var order := karts.duplicate()
	order.sort_custom(func(a: Kart, b: Kart) -> bool: return a.place < b.place)
	return order


func kart_ahead(k: Kart) -> Kart:
	for o in karts:
		if o.place == k.place - 1:
			return o
	return null


func kart_behind(k: Kart) -> Kart:
	for o in karts:
		if o.place == k.place + 1:
			return o
	return null


## kart-royale AIField.beginFrame: bots far behind the leader get a small speed
## band boost; a bot leading far ahead of the player eases off a little.
func _rubber_band(delta: float) -> void:
	if phase != Phase.RACING:
		return
	var lead := -INF
	for k in karts:
		if not k.finished:
			lead = maxf(lead, k.total_progress)
	for k in karts:
		if k.is_player or not (k.controller is AIController):
			continue
		var ai := k.controller as AIController
		var gap_to_lead := lead - k.total_progress
		var gap_to_player := k.total_progress - player.total_progress if player else 0.0
		var sc := F1.TRACK_SCALE
		var want := 1.0 + clampf((gap_to_lead - 30.0 * sc) / (80.0 * sc), 0.0, 1.0) * 0.05
		if gap_to_lead < 1.0:
			want -= clampf((gap_to_player - 40.0 * sc) / (110.0 * sc), 0.0, 1.0) * 0.04
		ai.band += clampf(want - ai.band, -delta * 0.3, delta * 0.3)


## Mines on the road, for the AI to steer around.
func hazards() -> Array:
	var out := []
	for p in projectiles:
		if p.alive and (p.kind == "mine" or p.kind == "bouncer"):
			out.append({"pos": p.position, "r": p.radius, "owner": p.owner_kart if p.owner_lock > 0.0 else null})
	return out


func _update_pickups(delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001
	for b in _boxes:
		var n: Node3D = b["node"]
		if b["respawn"] > 0.0:
			b["respawn"] -= delta
			if b["respawn"] <= 0.0:
				n.visible = true
				n.scale = Vector3.ONE * 0.1
			continue
		n.scale = n.scale.lerp(Vector3.ONE, clampf(delta * 6.0, 0.0, 1.0))
		n.rotation = Vector3(0.4, t * 1.6, 0.25)
		n.position.y = b["pos"].y + sin(t * 2.5 + b["pos"].x) * 0.15
		for k in karts:
			if k.global_position.distance_to(b["pos"]) < 1.9 + 0.6:
				n.visible = false
				b["respawn"] = 2.5
				if k.give_item_box():
					Game.sfx("item_pickup", b["pos"])
				break
	for o in _orbs:
		var n: Node3D = o["node"]
		if o["respawn"] > 0.0:
			o["respawn"] -= delta
			if o["respawn"] <= 0.0:
				n.visible = true
			continue
		n.position.y = o["pos"].y + sin(t * 4.0 + o["pos"].z) * 0.12
		for k in karts:
			if k.global_position.distance_to(o["pos"]) < 1.9:
				n.visible = false
				o["respawn"] = 12.0
				k.add_energy(8.0)
				if k.is_player:
					Game.sfx("energy_pickup", o["pos"])
				break


## kart-royale Items.use. Returns true if the item was consumed.
func use_item(k: Kart, item_name: String, backwards := false) -> bool:
	match item_name:
		"turbo", "turbo3":
			k.start_boost(Items.TURBO_TIME, Items.TURBO_STRENGTH)
			k.fx.emit("boost", 1.0)
			popup("VROOM!", k.global_position + Vector3.UP * 2.2, Game.ORANGE)
		"rampage":
			k.star_time = maxf(k.star_time, Items.RAMPAGE_TIME)
			k.start_boost(0.8, 1.2)
			popup("RAMPAGE!", k.global_position + Vector3.UP * 2.4, Game.YELLOW)
		"zap":
			_fire_zap(k)
		"bouncer", "rocket", "mine", "kaboom":
			var p := Items.Projectile.new()
			var tgt: Kart = null if backwards else kart_ahead(k)
			p.setup(item_name, k, backwards and item_name != "kaboom", tgt)
			add_child(p)
			p.reset_physics_interpolation()
			projectiles.append(p)
			Game.sfx({"bouncer": "bouncer_fire", "rocket": "rocket_fire", "mine": "mine_drop", "kaboom": "bomb_throw"}[item_name], k.global_position)
		_:
			return false
	Game.sfx("item_use", k.global_position)
	_item_stats[item_name + (" back" if backwards else "")] = _item_stats.get(item_name + (" back" if backwards else ""), 0) + 1
	return true


## ZAP!: every rival is squashed, stunned and shrunk for a while.
func _fire_zap(user: Kart) -> void:
	popup("ZAP!", user.global_position + Vector3.UP * 2.4, Game.YELLOW)
	for k in karts:
		if k == user or k.finished or k.star_time > 0.0:
			continue
		if k.squash_hit(Items.ZAP_STUN):
			k.shrink_time = Items.ZAP_TIME
			if k == player:
				camera.shake(0.5)
				hud.flash_big("ZAPPED!", Game.YELLOW, 0.8)


## RAMPAGE: a kart in rampage mode spins out and throws aside anyone it touches.
func _rampage_sweep() -> void:
	for s in karts:
		if s.star_time <= 0.0:
			continue
		for o in karts:
			if o == s or o.star_time > 0.0:
				continue
			var d := o.position_k - s.position_k
			if absf(d.y) > 2.0:
				continue
			d.y = 0.0
			if d.length_squared() > 3.2 * 3.2:
				continue
			if o.take_hit(1.25):
				var push := (d.normalized() if d.length_squared() > 1e-4 else Vector3(0, 0, 1)) * 11.0
				push.y = 5.5
				o.launch(push)
				on_item_hit(o, "rampage", o.global_position)


func _update_projectiles(delta: float) -> void:
	for p in projectiles:
		if p.alive and not p.tick(delta, self):
			p.alive = false
	for p in projectiles.filter(func(x): return not x.alive):
		projectiles.erase(p)
		p.queue_free()
	_rampage_sweep()


## A projectile struck a kart.
func on_item_hit(k: Kart, kind: String, pos: Vector3) -> void:
	_item_stats["HIT " + kind] = _item_stats.get("HIT " + kind, 0) + 1
	Game.sfx("item_hit", pos)
	popup({"bouncer": "BONK!", "rocket": "KA-POW!", "mine": "SPLAT!", "rampage": "WHAM!"}.get(kind, "POW!"), pos + Vector3.UP * 2.0, Game.ORANGE)
	_burst(pos, Game.YELLOW, 10, 0.4)


## kart-royale explode: blast radius with falloff, spin-out and launch.
func explode(p, scale := 1.0) -> void:
	var r := Items.BLAST_RADIUS * scale
	var pos: Vector3 = p.position
	for k in karts:
		if k == p.owner_kart and p.owner_lock > 0.0:
			continue
		var d := k.position_k - pos
		var dist := d.length()
		if dist > r or absf(d.y) > 5.0 or k.star_time > 0.0:
			continue
		var falloff := 1.0 - dist / r
		if k.take_hit(1.1 + 0.7 * falloff):
			d.y = 0.0
			var push := (d.normalized() if d.length_squared() > 1e-4 else Vector3(0, 0, 1)) * (6.0 * falloff)
			push.y = 5.5 * falloff + 1.5
			k.launch(push)
	Game.sfx("explosion", pos)
	popup(["BOOM!", "KA-BOOM!", "BLAM!"].pick_random(), pos + Vector3.UP * 2.0, Game.ORANGE)
	_burst(pos, Game.YELLOW, int(14 + 16 * scale), 0.6 * scale + 0.2)
	if player:
		var d := player.position_k.distance_to(pos)
		if d < 40.0:
			camera.shake(maxf(0.0, 0.7 * (1.0 - d / 40.0)) * scale, 0.4)


func _burst(pos: Vector3, color: Color, amount: int, size: float) -> void:
	var burst := CPUParticles3D.new()
	var m := SphereMesh.new()
	m.radius = size
	m.height = size * 2.0
	m.radial_segments = 8
	m.rings = 4
	burst.mesh = m
	burst.material_override = Toon.mat(color, false, Color(0.6, 0.35, 0.0))
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.amount = amount
	burst.lifetime = 0.6
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 4.0
	burst.initial_velocity_max = 9.0
	burst.gravity = Vector3(0, -6, 0)
	burst.scale_amount_curve = Kart._shrink_curve()
	add_child(burst)
	burst.global_position = pos
	burst.emitting = true
	get_tree().create_timer(1.2).timeout.connect(burst.queue_free)


func _on_hit(k: Kart) -> void:
	if k == player:
		camera.shake(1.0)


func _on_bumped(a: Kart, b: Kart, impulse: float) -> void:
	Game.sfx("kart_bump", a.global_position)
	if impulse > 7.0 and (a == player or b == player):
		popup("WHAM!" if impulse < 12.0 else "KRAK!", (a.global_position + b.global_position) * 0.5 + Vector3.UP * 1.8, Game.YELLOW)
		camera.shake(clampf((impulse - 7.0) / 15.0, 0.15, 0.6))


## Test helper (`-- --overlap-test`): how deep do karts overlap, and lap progress.
func _measure_overlap() -> void:
	if phase != Phase.RACING:
		return
	_ticks += 1
	var worst := 0.0
	for i in karts.size():
		for j in range(i + 1, karts.size()):
			var d := karts[i].position_k - karts[j].position_k
			d.y = 0.0
			worst = maxf(worst, Kart.KART_RADIUS * 2.0 - d.length())
	_worst_overlap = maxf(_worst_overlap, worst)
	if worst > 0.15:
		_overlap_ticks += 1
	if _ticks % 600 == 0:
		print("OVERLAP ticks=%d worst=%.3fm ticks_over_15cm=%d" % [_ticks, _worst_overlap, _overlap_ticks])
		var line := "  t=%.0fs " % race_time
		for k in ordered_karts():
			line += "%s:L%d/%.0f%%%s " % [k.display_name.substr(0, 4), k.lap, 100.0 * k.track_offset / track.length, "(F)" if k.finished else ""]
		print(line)
		print("  items: ", _item_stats)
		for k in karts:
			var prev: float = _prog_prev.get(k, -1.0)
			if prev >= 0.0 and k.total_progress - prev < 150.0 and not k.finished:
				var c := k.controller
				print("  STUCK %s t=%.3f v=%.1f lat=%.1f half=%.1f surf=%d gear=%d thr=%.1f brk=%.1f steer=%.2f spin=%.1f y=%.1f gy=%.1f" % [k.display_name, k.t, k.speed, track.lateral(k.position_k, track.closest_offset(k.position_k)), track.half_width_at(k.track_offset), k.surface, k.gearbox.gear, c.throttle, c.brake, c.steer, k.spin_time, k.position_k.y, k._ground_y])
			_prog_prev[k] = k.total_progress


func popup(text: String, pos: Vector3, color: Color) -> void:
	if text == "":
		return
	var p := ComicPopup.new()
	p.setup(text, color)
	add_child(p)
	p.global_position = pos


func _finish_everyone() -> void:
	# Estimate times for bots still racing so the results table is complete.
	for k in karts:
		if not k.finished:
			var remaining := (Game.laps + 1) * track.length - k.total_progress
			k.finish_time = race_time + maxf(remaining, 0.0) / (k.max_speed * 0.85)
			k.finished = true
	Game.last_results.clear()
	var order := karts.duplicate()
	order.sort_custom(func(a: Kart, b: Kart) -> bool: return a.finish_time < b.finish_time)
	for k in order:
		Game.last_results.append({"name": k.display_name, "time": k.finish_time, "is_player": k.is_player, "best": k.best_lap, "color": k.racer["body"]})
	race_finished.emit()
