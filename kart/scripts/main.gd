extends Node
## Root: switches between the main menu and a race.

var _current: Node


func _ready() -> void:
	Game.main = self
	# `-- --netlab --host|--client ...` opens the multiplayer lab (practical #4).
	if "--netlab" in OS.get_cmdline_user_args():
		start_netlab()
		return
	# `-- --race` on the command line jumps straight into a race (testing).
	if "--race" in OS.get_cmdline_user_args():
		start_race()
	else:
		show_menu()


func _swap(n: Node) -> void:
	get_tree().paused = false
	if _current:
		_current.queue_free()
	_current = n
	add_child(n)


func show_menu() -> void:
	_swap(MainMenu.new())


func start_race() -> void:
	_swap(Race.new())


## Practical work #4: networked prediction / reconciliation lab.
func start_netlab() -> void:
	var lab := NetLab.new()
	lab.name = "NetLab"  # same node path on every peer, required for RPCs
	_swap(lab)


# --- Test helpers: `-- --race --autoplay --shot=C:/path/out.png --shot-time=8` ---

func _enter_tree() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			var path := a.substr(7)
			var t := 6.0
			for b in OS.get_cmdline_user_args():
				if b.begins_with("--shot-time="):
					t = float(b.substr(12))
			_shoot(path, t)


func _shoot(path: String, t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	get_tree().quit()
