extends SceneTree
## Unit tests for Gearbox (pure model, no scene needed).
## Run: godot --headless --path kart --script res://tests/test_gearbox.gd

var _fails := 0


func _check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_fails += 1


## Drive multiplier after letting the engine settle at this speed and gear.
func _drive_at(speed: float, g: int) -> float:
	var gb := Gearbox.new()
	gb.manual = true
	gb.gear = g
	var m := 0.0
	for i in 120:
		m = gb.update(1.0 / 120.0, speed, 1.0, 0.0, false)
	return m


func _init() -> void:
	# Gear spacing: increasing top speeds, F1-like short first gear.
	var ok := true
	for g in range(2, Gearbox.GEARS + 1):
		ok = ok and Gearbox.gear_top_speed(g) > Gearbox.gear_top_speed(g - 1)
	_check(ok, "gear top speeds increase with each gear")
	var r1 := Gearbox.gear_top_speed(1) / Gearbox.gear_top_speed(Gearbox.GEARS)
	_check(r1 > 0.25 and r1 < 0.32, "1st gear reaches %.0f%% of top-gear speed (F1: ~29%%)" % (r1 * 100.0))

	# Skipping gears must not pay: at low speed a tall gear pulls much weaker.
	var low := 5.0
	_check(_drive_at(low, 1) > 2.5 * _drive_at(low, 6), "at 18 km/h, 1st pulls >2.5x harder than 6th (%.2f vs %.2f)" % [_drive_at(low, 1), _drive_at(low, 6)])
	# At high speed the lowest usable gear pulls clearly harder than 8th.
	var hi := 60.0
	var lowest := 0
	for g in range(1, Gearbox.GEARS + 1):
		if Gearbox.wheel_rpm(hi, g) <= Gearbox.LIMIT_RPM:
			lowest = g
			break
	_check(_drive_at(hi, lowest) > 1.3 * _drive_at(hi, Gearbox.GEARS), "at 216 km/h gear %d pulls >1.3x harder than 8th (%.2f vs %.2f)" % [lowest, _drive_at(hi, lowest), _drive_at(hi, Gearbox.GEARS)])
	_check(absf(Gearbox.gear_top_speed(1) * 3.6 - 100.0) < 1.0 and absf(Gearbox.gear_top_speed(8) * 3.6 - 350.0) < 1.0, "gear speeds are F1's (1st 100, 8th 350 km/h)")

	# Rev limiter cuts drive.
	var gb := Gearbox.new()
	gb.manual = true
	gb.gear = 1
	var at_lim := 0.0
	for i in 60:
		at_lim = gb.update(1.0 / 120.0, Gearbox.gear_top_speed(1) * 1.03, 1.0, 0.0, false)
	_check(gb.on_limiter and at_lim < 0.1, "rev limiter engages and cuts drive (%.2f)" % at_lim)

	# Downshift that would over-rev is held, then taken once revs allow.
	gb = Gearbox.new()
	gb.manual = true
	gb.gear = 5
	var fast := Gearbox.gear_top_speed(4) * 1.1
	gb.update(1.0 / 120.0, fast, 0.0, 1.0, false)
	gb.shift_down(fast)
	_check(gb.gear == 5 and gb.pending_down, "over-revving downshift is held, not dropped")
	var spd := fast
	for i in 120:
		spd -= 0.15
		gb.update(1.0 / 120.0, spd, 0.0, 1.0, false)
		if gb.gear == 4:
			break
	_check(gb.gear == 4 and Gearbox.wheel_rpm(spd, 4) <= Gearbox.LIMIT_RPM, "held downshift completes once revs allow")

	# Engine braking is stronger in a lower gear at the same speed.
	var eb := []
	for g in [6, 3]:
		var e := Gearbox.new()
		e.manual = true
		e.gear = g
		for i in 120:
			e.update(1.0 / 120.0, 40.0, 0.0, 0.0, false)
		eb.append(e.engine_brake)
	_check(eb[1] > eb[0] * 1.5, "engine braking in 3rd > 6th (%.3f vs %.3f)" % [eb[1], eb[0]])

	# Perfect shift only in the window.
	for case in [[14000.0, true], [11000.0, false]]:
		var p := Gearbox.new()
		p.manual = true
		p.gear = 3
		var target_speed: float = case[0] / Gearbox.LIMIT_RPM * Gearbox.gear_top_speed(3)
		for i in 240:
			p.update(1.0 / 120.0, target_speed, 1.0, 0.0, false)
		p.take_events()
		p.shift_up()
		var got := "perfect" in p.take_events()
		_check(got == case[1], "upshift at %.0f rpm %s a perfect shift" % [case[0], "is" if case[1] else "is not"])

	# Shift cooldown stops gear spamming.
	var s := Gearbox.new()
	s.manual = true
	s.shift_up()
	s.shift_up()
	s.shift_up()
	_check(s.gear == 2, "repeated presses within the cooldown shift only once")

	print("%d failed" % _fails)
	quit(1 if _fails > 0 else 0)
