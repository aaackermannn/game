extends Node
## Automated QA walk-through, started with `-- --qa --autoplay [--laps=1] --qa-out=<dir>`.
## Drives the real game flow the way a player would and records what happened:
## race to the flag -> results -> RACE AGAIN -> pause/resume -> F5 restart ->
## MAIN MENU -> cycle every menu option -> start a race from the menu.
## Writes screenshots and qa_report.txt into --qa-out, then quits.

var out_dir := "user://qa"
var _log: PackedStringArray = []
var _fails := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--qa-out="):
			out_dir = a.substr(9)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _note(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	var line := ("PASS  " if ok else "FAIL  ") + what
	_log.append(line)
	print("QA ", line)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img:
		img.save_png(out_dir.path_join(name + ".png"))


func _race() -> Race:
	return Game.main._current as Race


## Sends a real input event, so it reaches the game exactly like a key press.
func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame


## Waits until `cond` is true (polled every 0.25 s) or the timeout passes.
func _until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await _wait(0.25)
		t += 0.25
	return cond.call()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	# 1. Race to the flag.
	var ok := await _until(func(): return _race() != null and _race().phase == Race.Phase.RACING, 20.0)
	_note(ok, "countdown ends and the race starts")
	await _wait(4.0)
	var r := _race()
	_note(r.player.speed > 5.0, "player kart is driving (%.1f m/s)" % r.player.speed)
	_note(r.karts.all(func(k): return k.speed > 3.0), "all karts are moving after the start")
	await _shot("01_racing")
	var lap_limit := 150.0 * Game.laps + 60.0  # 4.8 km F1-scale lap
	ok = await _until(func(): return _race().phase == Race.Phase.FINISHED, lap_limit)
	_note(ok, "player finishes %d lap(s) within %.0f s (race time %.1f s)" % [Game.laps, lap_limit, _race().race_time])
	ok = await _until(func(): return _race().hud.results_visible(), 15.0)
	_note(ok, "results screen appears after the finish")
	_note(Game.last_results.size() == _race().karts.size(), "results list every racer (%d/%d)" % [Game.last_results.size(), _race().karts.size()])
	var times_ok := true
	for i in range(1, Game.last_results.size()):
		times_ok = times_ok and float(Game.last_results[i]["time"]) >= float(Game.last_results[i - 1]["time"])
	_note(times_ok, "results are sorted by finish time")
	await _shot("02_results")

	# 2. RACE AGAIN from the results screen.
	var old := _race()
	Game.main.start_race()
	await _wait(1.0)
	_note(_race() != null and _race() != old and not is_instance_valid(old), "RACE AGAIN builds a fresh race and frees the old one")
	ok = await _until(func(): return _race().phase == Race.Phase.RACING, 20.0)
	_note(ok, "second race starts")
	await _wait(3.0)

	# 3. Pause / resume.
	await _press("pause")
	await _wait(0.3)
	_note(get_tree().paused, "ESC pauses the game")
	var t_before := _race().race_time
	await _wait(1.0)
	_note(is_equal_approx(_race().race_time, t_before), "race clock stops while paused")
	await _shot("03_paused")
	await _press("pause")
	await _wait(0.5)
	_note(not get_tree().paused, "ESC resumes the game")
	await _wait(1.0)
	_note(_race().race_time > t_before, "race clock runs again after resume")

	# 4. F5 restart.
	old = _race()
	await _press("restart_race")
	await _wait(1.0)
	_note(_race() != old, "F5 restarts the race")
	ok = await _until(func(): return _race().phase == Race.Phase.RACING, 20.0)
	_note(ok, "restarted race starts")
	await _wait(2.0)

	# 5. Pause menu -> MAIN MENU.
	await _press("pause")
	await _wait(0.3)
	var quit_btn := _find_button(_race().hud, "MAIN MENU")
	_note(quit_btn != null, "pause menu has a MAIN MENU button")
	if quit_btn:
		quit_btn.pressed.emit()
	await _wait(1.5)
	var menu := Game.main._current as MainMenu
	_note(menu != null and not get_tree().paused, "MAIN MENU opens the menu and unpauses")
	await _shot("04_menu")

	# 6. Menu options.
	if menu:
		for key in ["racer", "laps", "rivals", "difficulty"]:
			var b: Button = menu._rows[key]
			var before := b.text
			b.pressed.emit()
			await get_tree().process_frame
			_note(b.text != before, "menu option '%s' changes (%s -> %s)" % [key, before.strip_edges(), b.text.strip_edges()])
		Game.bot_count = 7
		menu._refresh()
		menu._rows["rivals"].pressed.emit()
		_note(Game.bot_count == 0, "RIVALS wraps from 7 to 0")
		menu._rows["rivals"].pressed.emit()
		Game.laps = 9
		menu._refresh()
		menu._rows["laps"].pressed.emit()
		_note(Game.laps == 1, "LAPS wraps from 9 to 1")
		await _wait(0.5)
		await _shot("05_menu_changed")
		var race_btn := _find_button(menu, "RACE!")
		_note(race_btn != null, "menu has a RACE! button")
		if race_btn:
			race_btn.pressed.emit()
		await _wait(1.0)
		_note(_race() != null, "RACE! starts a race from the menu")
		ok = await _until(func(): return _race() != null and _race().phase == Race.Phase.RACING, 20.0)
		_note(ok, "race started from the menu runs (%d karts, %d laps)" % [_race().karts.size() if _race() else 0, Game.laps])
		await _wait(3.0)
		await _shot("06_menu_race")

	# 7. Edge case: a solo race (RIVALS 0).
	Game.bot_count = 0
	Game.main.start_race()
	var solo := await _until(func(): return _race() != null and _race().phase == Race.Phase.RACING, 20.0)
	_note(solo and _race().karts.size() == 1, "solo race with 0 rivals starts")
	await _wait(4.0)
	_note(_race().player.speed > 5.0 and _race().player.place == 1, "solo race runs (player 1st, %.1f m/s)" % _race().player.speed)
	await _shot("07_solo")

	_log.append("")
	_log.append("%d checks failed, total time %.0f s" % [_fails, (Time.get_ticks_msec() - t0) / 1000.0])
	var f := FileAccess.open(out_dir.path_join("qa_report.txt"), FileAccess.WRITE)
	f.store_string("\n".join(_log))
	f.close()
	print("QA DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text.strip_edges() == text:
			return n
	return null
