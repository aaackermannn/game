class_name NetLab
extends Node3D
## NET LAB — practical work #4: client-side prediction, server reconciliation
## and network-emulation experiments, done in Godot 4.4 instead of Unreal.
##
## Topology: LISTEN SERVER. The host process is the server AND player 1; other
## processes join as clients. Mapping to Unreal's roles:
##   NetLab (server part)      ~ GameMode: spawns players, owns the rules, validates.
##   NetLab (input sampling)   ~ PlayerController: reads keys, sends intent / RPCs.
##   NetKartView + NetSim.State~ Character: replicated kart state and the dash action.
##   NetSim.step + saved moves ~ CharacterMovementComponent: move simulation,
##                               saved moves, ServerMove, ClientAdjustPosition, replay.
##   own kart on a client      = Autonomous Proxy (predicted, reconciled)
##   other karts on a client   = Simulated Proxy  (interpolated snapshots)
##
## Command line (after `--`):  --netlab [--host | --client] [--ip=127.0.0.1]
##   [--port=27100] [--csp=0|1] [--profile=0|1|2] [--autodrive] [--slot=N]
##   [--timeline=file] [--log=file.csv] [--capture=dir] [--capture-fps=20]
##   [--caption=text] [--seed=N]

const DEFAULT_PORT := 27100
const SNAPSHOT_EVERY := 2           # server ticks between snapshots (30 Hz)
const REDUNDANT_INPUTS := 12        # unacked inputs repeated in every packet
const MAX_SAVED_MOVES := 240
const CORRECTION_EPS := 0.02
const INTERP_TICKS := 6.0           # simulated proxies render 100 ms in the past
const MOVE_BUDGET_MAX := 0.3        # seconds of moves a client may bank (anti speed-hack)
const SMOOTH_TIME := 0.12

enum Role { NONE, SERVER, CLIENT }

class SavedMove:
	var input: NetSim.Cmd
	var state: NetSim.State        # predicted state AFTER applying input

class ServerPlayer:
	var peer := 0
	var slot := 0
	var state: NetSim.State
	var last_seq := -1
	var budget := 0.0
	var dash_ok := 0
	var dash_rejected := 0
	var budget_rejects := 0
	var gaps := 0
	var last_input := NetSim.Cmd.new()

class RemoteKart:
	var slot := 0
	var view: NetKartView
	var buffer: Array = []          # [[tick, State], ...]

var role := Role.NONE
var emu := NetEmu.new()

# settings (console / command line)
var dash_prediction := true         # CSP for the dash action
var move_prediction := true         # CSP for ordinary movement
var cheat_ignore_cooldown := false
var cheat_speed_mult := 1.0
var cheat_double_tick := false
var show_ghost := true
var cam_follow_client := false      # server window: camera on the first remote client
var autodrive := false
var caption := ""

# --- server side -------------------------------------------------------------
var _players := {}                  # peer -> ServerPlayer
var _server_tick := 0
var _next_slot := 0

# --- client side -------------------------------------------------------------
var _my_id := 0
var _my_slot := 0
var _spawned := false
var _pred := NetSim.State.new()     # predicted own state (autonomous proxy)
var _server_own := NetSim.State.new()
var _server_own_tick := -1
var _own_buffer: Array = []         # for the "no movement prediction" display
var _saved: Array = []              # SavedMove, oldest first
var _seq := 0
var _last_snapshot_tick := -1
var _remotes := {}                  # peer -> RemoteKart
var _render_tick := -1.0
var _latest_tick := 0
var _smooth := Vector2.ZERO         # visual-only correction smoothing offset
var _rtt := -1.0
var _ping_timer := 0
var _dash_req := 0
var _seen_cooldown := 0
var _dash_was_down := false
var _scripted_dash := false

# measurements
var corrections := 0
var last_correction := 0.0
var dash_ok := 0
var dash_rejected := 0
var _press_ms := -1.0
var _press_mode := ""
var _latencies: Array = []
var last_latency := -1.0
var _events: Array[String] = []
var _log_file: FileAccess
var _t0_ms := 0.0
var _t_spawn := 0.0
var _timeline: Array = []

# presentation
var _own_view: NetKartView
var _ghost: Node3D
var _cam: Camera3D
var _hud_stats: Label
var _hud_events: Label
var _hud_caption: Label
var _caption_panel: PanelContainer
var _console: LineEdit
var _lobby: Control
var _ip_edit: LineEdit
var _capture_dir := ""
var _capture_every := 0.05
var _capture_acc := 0.0
var _capture_n := 0
var _save_tasks: Array = []


func _ready() -> void:
	name = "NetLab"
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	Engine.physics_ticks_per_second = NetSim.TICK_RATE
	_t0_ms = Time.get_ticks_usec() / 1000.0
	_add_dash_action()
	_build_world()
	_build_hud()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func(): _log("connected", {"peer": multiplayer.get_unique_id()}))
	multiplayer.connection_failed.connect(func(): _log("connection_failed", {}))
	multiplayer.server_disconnected.connect(func(): _log("server_disconnected", {}))
	_apply_args()


func _exit_tree() -> void:
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if _log_file:
		_log_file.close()


# ============================================================================
# Startup
# ============================================================================

func _apply_args() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = str(a).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("log"):
		_log_file = FileAccess.open(args["log"], FileAccess.WRITE)
		if _log_file:
			_log_file.store_line("t_ms,wall_ms,role,event,details")
	if args.has("seed"):
		emu = NetEmu.new(int(args["seed"]))
	if args.has("csp"):
		dash_prediction = args["csp"] != "0"
	if args.has("move-prediction"):
		move_prediction = args["move-prediction"] != "0"
	if args.has("profile"):
		emu.apply_profile(clampi(int(args["profile"]), 0, 2))
	if args.has("autodrive"):
		autodrive = true
	if args.has("cam-client"):
		cam_follow_client = true
	if args.has("caption"):
		_set_caption(args["caption"])
	if args.has("slot"):
		_next_slot = int(args["slot"])
	if args.has("timeline"):
		_load_timeline(args["timeline"])
	if args.has("capture"):
		_capture_dir = args["capture"]
		DirAccess.make_dir_recursive_absolute(_capture_dir)
		_capture_every = 1.0 / float(args.get("capture-fps", "20"))
	var port := int(args.get("port", str(DEFAULT_PORT)))
	if args.has("host"):
		start_host(port)
	elif args.has("client"):
		start_client(args.get("ip", "127.0.0.1"), port)
	else:
		_show_lobby()


func start_host(port := DEFAULT_PORT) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 8)
	if err != OK:
		_log("host_failed", {"err": err})
		return
	multiplayer.multiplayer_peer = peer
	role = Role.SERVER
	_my_id = 1
	_hide_lobby()
	_add_server_player(1)
	_log("listen_server_started", {"port": port})
	get_window().title = "NET LAB - LISTEN SERVER (player 1)"


func start_client(ip: String, port := DEFAULT_PORT) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		_log("client_failed", {"err": err})
		return
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	_hide_lobby()
	_log("client_connecting", {"ip": ip, "port": port})
	get_window().title = "NET LAB - CLIENT"


func _add_dash_action() -> void:
	if InputMap.has_action("dash"):
		return
	InputMap.add_action("dash", 0.25)
	for k in [KEY_SPACE, KEY_SHIFT, KEY_E]:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event("dash", e)
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_X
	InputMap.action_add_event("dash", jb)


# ============================================================================
# Main loop
# ============================================================================

func _physics_process(_delta: float) -> void:
	_run_timeline()
	if role == Role.SERVER:
		_server_tick_step()
	elif role == Role.CLIENT and _spawned:
		_client_tick()
		if cheat_double_tick:
			_client_tick()  # speed-hack: twice as many moves as real time allows


func _process(delta: float) -> void:
	emu.flush()
	if role == Role.CLIENT:
		_smooth = _smooth.lerp(Vector2.ZERO, clampf(delta / SMOOTH_TIME, 0.0, 1.0))
		_render_client(delta)
	elif role == Role.SERVER:
		_render_server()
	_update_camera(delta)
	_update_hud()
	_capture(delta)
	if _press_ms >= 0.0 and _now() - _press_ms > 1500.0:
		_log("dash_no_reaction", {"mode": _press_mode, "waited_ms": int(_now() - _press_ms)})
		_press_ms = -1.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_F1, KEY_QUOTELEFT:
				_toggle_console()
			KEY_F2:
				var p := 0
				for i in NetEmu.PROFILES.size():
					if _profile_matches(i):
						p = (i + 1) % NetEmu.PROFILES.size()
				exec("net.Profile %d" % p)
			KEY_F3: exec("net.DashPrediction %d" % (0 if dash_prediction else 1))
			KEY_F4: exec("net.MovePrediction %d" % (0 if move_prediction else 1))
			KEY_F6: exec("cheat.IgnoreCooldown %d" % (0 if cheat_ignore_cooldown else 1))
			KEY_F7: exec("cheat.SpeedMult %s" % ("1" if cheat_speed_mult != 1.0 else "1.6"))
			KEY_F8: exec("show.Ghost %d" % (0 if show_ghost else 1))
			KEY_F9: exec("autodrive %d" % (0 if autodrive else 1))
			KEY_ESCAPE:
				if _console.visible:
					_toggle_console()
				else:
					Game.main.show_menu()


func _profile_matches(i: int) -> bool:
	var probe := NetEmu.new()
	probe.apply_profile(i)
	return probe.describe() == emu.describe()


# ============================================================================
# Input sampling (PlayerController role)
# ============================================================================

func _sample_input() -> NetSim.Cmd:
	var i := NetSim.Cmd.new()
	var console_open := _console and _console.visible
	if autodrive:
		var s: NetSim.State = _pred if role == Role.CLIENT else (_players[1] as ServerPlayer).state
		_autodrive(s, i)
	elif not console_open:
		i.throttle = Input.get_action_strength("accelerate") - Input.get_action_strength("brake")
		i.steer = Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	var down := (not console_open and Input.is_action_pressed("dash")) or _scripted_dash
	i.dash = down and not _dash_was_down   # one request per key press
	_dash_was_down = down and not _scripted_dash
	_scripted_dash = false
	return i


## Simple waypoint loop around the pillars, used for reproducible experiments.
const LOOP := [Vector2(-26, -18), Vector2(26, -18), Vector2(26, 18), Vector2(-26, 18)]
var _wp := -1

func _autodrive(s: NetSim.State, i: NetSim.Cmd) -> void:
	if _wp < 0:
		var best := 1e9
		for k in LOOP.size():
			var dist: float = s.pos.distance_to(LOOP[k])
			if dist < best:
				best = dist
				_wp = (k + 1) % LOOP.size()
	var target: Vector2 = LOOP[_wp]
	if s.pos.distance_to(target) < 7.0:
		_wp = (_wp + 1) % LOOP.size()
		target = LOOP[_wp]
	var d := target - s.pos
	var want := atan2(-d.x, -d.y)
	var diff := angle_difference(s.heading, want)
	i.steer = clampf(diff * 2.5, -1.0, 1.0)
	i.throttle = 0.55 if absf(diff) > 0.9 else 1.0


# ============================================================================
# SERVER (authority): GameMode + server half of the movement component
# ============================================================================

func _add_server_player(peer: int) -> void:
	var p := ServerPlayer.new()
	p.peer = peer
	p.slot = _next_slot
	_next_slot += 1
	p.state = NetSim.spawn_state(p.slot)
	_players[peer] = p
	var view := NetKartView.new()
	add_child(view)
	var you := peer == 1
	view.setup(p.slot, ("YOU (HOST)" if you else "P%d" % (p.slot + 1)), Game.YELLOW if you else Game.CYAN)
	view.name = "Kart_%d" % peer
	if you:
		_own_view = view
	_log("spawn", {"peer": peer, "slot": p.slot})


func _on_peer_connected(peer: int) -> void:
	if role == Role.SERVER:
		_add_server_player(peer)


func _on_peer_disconnected(peer: int) -> void:
	if role == Role.SERVER and _players.has(peer):
		_players.erase(peer)
		var v := get_node_or_null("Kart_%d" % peer)
		if v:
			v.queue_free()
		_log("despawn", {"peer": peer})


func _server_tick_step() -> void:
	_server_tick += 1
	for p: ServerPlayer in _players.values():
		p.budget = minf(p.budget + NetSim.DT, MOVE_BUDGET_MAX)
	# The host's own kart is simulated right here (it is the authority).
	var host: ServerPlayer = _players.get(1)
	if host:
		var i := _sample_input()
		i.seq = _server_tick
		_server_apply(host, i)
	if _server_tick % SNAPSHOT_EVERY == 0:
		_broadcast_snapshot()


## ServerMove: validate and apply ONE input. Never accepts a position.
func _server_apply(p: ServerPlayer, i: NetSim.Cmd) -> void:
	if p.peer != 1:
		if p.budget < NetSim.DT * 0.5:
			p.budget_rejects += 1
			if p.budget_rejects % 30 == 1:
				_log("server_reject_move", {"peer": p.peer, "seq": i.seq, "why": "move_budget (speed hack?)", "total": p.budget_rejects})
			p.last_seq = i.seq  # acknowledged but NOT simulated -> client gets corrected
			return
		p.budget -= NetSim.DT
	var verdict := NetSim.step(p.state, i)
	p.last_input = i
	if i.dash:
		_server_dash_verdict(p, verdict, i.seq)
	p.last_seq = i.seq


## `id` is the input seq (CSP path) or the request id (RPC path).
func _server_dash_verdict(p: ServerPlayer, verdict: int, seq: int, path := "input") -> void:
	if verdict == NetSim.DashReject.OK:
		p.dash_ok += 1
		_log("server_dash_accept", {"peer": p.peer, "path": path, "id": seq})
	else:
		p.dash_rejected += 1
		_log("server_dash_reject", {"peer": p.peer, "path": path, "id": seq, "why": NetSim.REJECT_NAMES[verdict],
			"cooldown_left_ms": int(p.state.cooldown_ticks * 1000.0 / NetSim.TICK_RATE)})
		if p.peer == 1:
			_own_view.pop("NO!", Game.RED)
		else:
			_send(p.peer, "_rpc_dash_result", [seq, false, verdict], true)


func _broadcast_snapshot() -> void:
	var entries := []
	for p: ServerPlayer in _players.values():
		entries.append([p.peer, p.slot, p.state.to_array(), p.last_seq])
	for p: ServerPlayer in _players.values():
		if p.peer != 1:
			_send(p.peer, "_rpc_snapshot", [_server_tick, entries], false)


func _render_server() -> void:
	for p: ServerPlayer in _players.values():
		var v: NetKartView = get_node_or_null("Kart_%d" % p.peer)
		if v:
			v.show_state(p.state)
	_ghost.visible = false


# --- RPC endpoints on the server --------------------------------------------

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_inputs(packed: Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	emu.receive(func(): _srv_on_inputs(sender, packed), false)


func _srv_on_inputs(sender: int, packed: Array) -> void:
	var p: ServerPlayer = _players.get(sender)
	if p == null:
		return
	for a in packed:
		if not (a is Array) or a.size() != 4:
			continue
		var i := NetSim.Cmd.from_array(a)
		if i.seq <= p.last_seq:
			continue  # redundant copy of something already simulated
		if i.seq > p.last_seq + 1 and p.last_seq >= 0:
			p.gaps += 1
		_server_apply(p, i)


## Baseline (no-CSP) path: the dash is a separate reliable RPC and the client
## shows nothing until the server's state comes back.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_dash(req_id: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	emu.receive(func(): _srv_on_dash_request(sender, req_id), true)


func _srv_on_dash_request(sender: int, req_id: int) -> void:
	var p: ServerPlayer = _players.get(sender)
	if p == null:
		return
	var verdict := NetSim.dash_check(p.state)
	if verdict == NetSim.DashReject.OK:
		p.state.dash_ticks = NetSim.DASH_TICKS
		p.state.cooldown_ticks = NetSim.DASH_COOLDOWN_TICKS
	_server_dash_verdict(p, verdict, req_id, "rpc")


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_ping(t: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	emu.receive(func(): _send(sender, "_rpc_pong", [t], false), false)


# ============================================================================
# CLIENT: autonomous proxy (prediction + reconciliation) and simulated proxies
# ============================================================================

func _client_tick() -> void:
	var i := _sample_input()
	_seq += 1
	i.seq = _seq
	if i.dash:
		_press_ms = _now()
		_press_mode = "CSP" if dash_prediction else "RPC"
		_log("dash_press", {"seq": _seq, "mode": _press_mode, "net": emu.describe()})
		if not dash_prediction:
			_dash_req += 1
			_send(1, "_rpc_request_dash", [_dash_req], true)
			i.dash = false  # do NOT simulate it locally — wait for the server
	# Client-side prediction: apply the input to our own kart right now.
	var verdict := NetSim.step(_pred, i, cheat_ignore_cooldown, cheat_speed_mult)
	if i.dash and verdict != NetSim.DashReject.OK:
		_own_view.pop("WAIT", Game.PAPER)
		_log("client_dash_blocked_locally", {"why": NetSim.REJECT_NAMES[verdict]})
		_press_ms = -1.0  # honest prediction: we already know the server will say no
	var m := SavedMove.new()
	m.input = i
	m.state = _pred.copy()
	_saved.append(m)
	if _saved.size() > MAX_SAVED_MOVES:
		_saved.pop_front()
	# Send intent, never the position. Unacked inputs ride along for loss tolerance.
	var packed := []
	for k in range(maxi(0, _saved.size() - REDUNDANT_INPUTS), _saved.size()):
		packed.append((_saved[k] as SavedMove).input.to_array())
	_send(1, "_rpc_inputs", [packed], false)
	_check_reaction()
	_ping_timer += 1
	if _ping_timer % 30 == 0:
		_send(1, "_rpc_ping", [_now()], false)


@rpc("authority", "call_remote", "unreliable")
func _rpc_snapshot(tick: int, entries: Array) -> void:
	emu.receive(func(): _cl_on_snapshot(tick, entries), false)


func _cl_on_snapshot(tick: int, entries: Array) -> void:
	if tick <= _last_snapshot_tick:
		return  # late / reordered packet
	_last_snapshot_tick = tick
	_latest_tick = tick
	if _my_id == 0:
		_my_id = multiplayer.get_unique_id()
	var seen := {}
	for e in entries:
		var peer: int = e[0]
		var slot: int = e[1]
		var st := NetSim.State.from_array(e[2])
		seen[peer] = true
		if peer == _my_id:
			if not _spawned:
				_spawn_self(slot, st)
			_server_own = st
			_server_own_tick = tick
			_own_buffer.append([tick, st])
			if _own_buffer.size() > 40:
				_own_buffer.pop_front()
			_reconcile(st, int(e[3]))
		else:
			var r: RemoteKart = _remotes.get(peer)
			if r == null:
				r = RemoteKart.new()
				r.slot = slot
				r.view = NetKartView.new()
				r.view.name = "Kart_%d" % peer
				add_child(r.view)
				r.view.setup(slot, "HOST" if peer == 1 else "P%d" % (slot + 1), Game.CYAN)
				_remotes[peer] = r
			r.buffer.append([tick, st])
			if r.buffer.size() > 40:
				r.buffer.pop_front()
	for peer in _remotes.keys():
		if not seen.has(peer):
			(_remotes[peer] as RemoteKart).view.queue_free()
			_remotes.erase(peer)


func _spawn_self(slot: int, st: NetSim.State) -> void:
	_spawned = true
	_my_slot = slot
	_pred = st.copy()
	_own_view = NetKartView.new()
	_own_view.name = "Kart_self"
	add_child(_own_view)
	_own_view.setup(slot, "YOU (CLIENT)", Game.YELLOW)
	_t_spawn = _now()
	_log("spawned_self", {"peer": _my_id, "slot": slot})
	get_window().title = "NET LAB - CLIENT %d" % _my_id


## ClientAdjustPosition + replay of saved moves.
func _reconcile(server: NetSim.State, ack: int) -> void:
	var predicted: NetSim.State = null
	while not _saved.is_empty() and (_saved[0] as SavedMove).input.seq <= ack:
		var m: SavedMove = _saved.pop_front()
		if m.input.seq == ack:
			predicted = m.state
	var err := 999.0 if predicted == null else predicted.error_to(server)
	if err <= CORRECTION_EPS:
		return  # prediction confirmed — nothing to do
	var before := _pred.pos
	var cur := server.copy()
	for m: SavedMove in _saved:
		NetSim.step(cur, m.input, cheat_ignore_cooldown, cheat_speed_mult)
		m.state = cur.copy()
	_pred = cur
	if predicted == null:
		return
	corrections += 1
	last_correction = before.distance_to(_pred.pos)
	_smooth += before - _pred.pos  # hide the snap over SMOOTH_TIME (visual only)
	if _smooth.length() > 6.0:
		_smooth = Vector2.ZERO      # too big to smooth: snap honestly
	var why := "position"
	if predicted.dash_ticks != server.dash_ticks or predicted.cooldown_ticks != server.cooldown_ticks:
		why = "dash_state"
	_log("client_correction", {"ack": ack, "err": snappedf(err, 0.001), "snap_m": snappedf(last_correction, 0.01),
		"why": why, "replayed": _saved.size()})
	if last_correction > 0.3 or why == "dash_state":
		_own_view.pop("CORRECTED!", Game.RED)
	_check_reaction()


@rpc("authority", "call_remote", "reliable")
func _rpc_dash_result(seq_or_req: int, ok: bool, reason: int) -> void:
	emu.receive(_cl_on_dash_result.bind(seq_or_req, ok, reason), true)


func _cl_on_dash_result(seq_or_req: int, ok: bool, reason: int) -> void:
	if ok:
		dash_ok += 1
		return
	dash_rejected += 1
	_press_ms = -1.0
	if _own_view:
		_own_view.pop("REJECTED: %s" % str(NetSim.REJECT_NAMES[reason]).to_upper(), Game.RED)
	_log("client_dash_rejected_by_server", {"id": seq_or_req, "why": NetSim.REJECT_NAMES[reason]})


@rpc("authority", "call_remote", "unreliable")
func _rpc_pong(t: float) -> void:
	emu.receive(_cl_on_pong.bind(t), false)


func _cl_on_pong(t: float) -> void:
	var sample := _now() - t
	_rtt = sample if _rtt < 0.0 else lerpf(_rtt, sample, 0.25)


func _displayed_own() -> NetSim.State:
	if move_prediction:
		return _pred
	return _interp(_own_buffer, _render_tick)


## Press -> first frame where our own kart is visibly dashing.
## A dash "started" when the cooldown jumps up. Without prediction the server's
## dash may already be over when its state arrives (it lasts 200 ms, less than
## the RTT), so the client only sees the kart lurch forward — that is the reaction.
func _check_reaction() -> void:
	if not _spawned:
		return
	var s := _displayed_own()
	if s == null:
		return
	var started := s.cooldown_ticks > _seen_cooldown + 10
	_seen_cooldown = s.cooldown_ticks
	if _press_ms >= 0.0 and started:
		var ms := _now() - _press_ms
		last_latency = ms
		_latencies.append(ms)
		_log("dash_reaction", {"mode": _press_mode, "latency_ms": snappedf(ms, 0.1), "rtt_ms": snappedf(_rtt, 0.1), "net": emu.describe()})
		_press_ms = -1.0


func _render_client(delta: float) -> void:
	if not _spawned:
		return
	# Clock for simulated proxies: stay INTERP_TICKS behind the newest snapshot.
	var target := _latest_tick - INTERP_TICKS
	if _render_tick < 0.0 or absf(_render_tick - target) > 12.0:
		_render_tick = target
	else:
		_render_tick += delta * NetSim.TICK_RATE
		_render_tick = lerpf(_render_tick, target, 0.05)
	for r: RemoteKart in _remotes.values():
		var s := _interp(r.buffer, _render_tick)
		if s:
			r.view.show_state(s)
	var own := _displayed_own()
	if own:
		_own_view.show_state(own, _smooth if move_prediction else Vector2.ZERO)
	if not move_prediction:
		_check_reaction()
	_ghost.visible = show_ghost and _server_own_tick >= 0
	if _ghost.visible:
		_ghost.position = Vector3(_server_own.pos.x, 0.0, _server_own.pos.y)
		_ghost.rotation.y = _server_own.heading


func _interp(buf: Array, t: float) -> NetSim.State:
	if buf.is_empty():
		return null
	if t <= buf[0][0]:
		return buf[0][1]
	for k in range(buf.size() - 1):
		var a: Array = buf[k]
		var b: Array = buf[k + 1]
		if t >= a[0] and t <= b[0]:
			var u: float = (t - float(a[0])) / float(b[0] - a[0])
			var sa: NetSim.State = a[1]
			var sb: NetSim.State = b[1]
			var s := sb.copy()
			s.pos = sa.pos.lerp(sb.pos, u)
			s.heading = lerp_angle(sa.heading, sb.heading, u)
			s.speed = lerpf(sa.speed, sb.speed, u)
			s.dash_ticks = sa.dash_ticks if u < 0.5 else sb.dash_ticks
			return s
	return buf[buf.size() - 1][1]


# ============================================================================
# Transport helper: every message goes through the emulator
# ============================================================================

func _send(peer: int, method: String, args: Array, reliable: bool) -> void:
	emu.send(_deliver.bind(peer, method, args), reliable)


func _deliver(peer: int, method: String, args: Array) -> void:
	var mp := multiplayer.multiplayer_peer
	if mp == null or mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if role == Role.SERVER and not (peer in multiplayer.get_peers()):
		return
	callv("rpc_id", [peer, method] + args)


# ============================================================================
# Console (Unreal-style) and timeline scripting
# ============================================================================

func exec(line: String) -> void:
	line = line.strip_edges()
	if line == "":
		return
	var parts := line.split(" ", false)
	var key := parts[0].to_lower()
	var arg := parts[1] if parts.size() > 1 else ""
	var on := arg != "0" and arg != ""
	var result := ""
	if key.begins_with("netemulation."):
		result = emu.command(line)
	else:
		match key:
			"net.profile":
				emu.apply_profile(clampi(int(arg), 0, 2))
				result = "profile %s -> %s" % [NetEmu.PROFILES[clampi(int(arg), 0, 2)]["name"], emu.describe()]
			"net.dashprediction":
				dash_prediction = on
				result = "dash CSP " + ("ON" if on else "OFF (server RPC only)")
			"net.moveprediction":
				move_prediction = on
				result = "movement prediction " + ("ON" if on else "OFF")
			"cheat.ignorecooldown":
				cheat_ignore_cooldown = on
				result = "client ignores dash cooldown: %s" % on
			"cheat.speedmult":
				cheat_speed_mult = maxf(float(arg), 0.1) if arg != "" else 1.0
				result = "client speed multiplier: %s" % cheat_speed_mult
			"cheat.doubletick":
				cheat_double_tick = on
				result = "client sends 2 moves per tick: %s" % on
			"cam.followclient":
				cam_follow_client = on
				result = "server camera follows client: %s" % on
			"show.ghost":
				show_ghost = on
				result = "server ghost: %s" % on
			"autodrive":
				autodrive = on
				_wp = -1
				result = "autodrive: %s" % on
			"dash":
				_scripted_dash = true
				result = "dash pressed (scripted)"
			"caption":
				_set_caption(line.substr(8))
				result = "caption set"
			"shot":
				_screenshot(line.substr(5))
				result = "screenshot " + line.substr(5)
			"stats":
				result = _stats_line()
			"quit":
				_log("quit", {"stats": _stats_line()})
				get_tree().quit()
				return
			_:
				result = "unknown command"
	_log("console", {"cmd": line, "result": result})


func _load_timeline(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_log("timeline_missing", {"path": path})
		return
	while not f.eof_reached():
		var l := f.get_line().strip_edges()
		if l == "" or l.begins_with("#"):
			continue
		var sp := l.find(" ")
		if sp < 0:
			continue
		_timeline.append([float(l.substr(0, sp)), l.substr(sp + 1)])
	_timeline.sort_custom(func(a, b): return a[0] < b[0])


func _run_timeline() -> void:
	if _timeline.is_empty():
		return
	var started := (role == Role.CLIENT and _spawned) or (role == Role.SERVER)
	if not started:
		return
	var origin := _t_spawn if role == Role.CLIENT else _t0_ms
	var t := (_now() - origin) / 1000.0
	while not _timeline.is_empty() and _timeline[0][0] <= t:
		var e: Array = _timeline.pop_front()
		exec(e[1])


# ============================================================================
# Logging / measurements
# ============================================================================

func _now() -> float:
	return Time.get_ticks_usec() / 1000.0


func _role_name() -> String:
	return ["none", "server", "client"][role]


func _log(event: String, data: Dictionary) -> void:
	var t := _now() - _t0_ms
	var parts := PackedStringArray()
	for k in data:
		parts.append("%s=%s" % [k, data[k]])
	var details := " ".join(parts)
	print("[NETLAB][%s][%8.1f] %s %s" % [_role_name(), t, event, details])
	if _log_file:
		_log_file.store_line("%.1f,%d,%s,%s,\"%s\"" % [t, int(Time.get_unix_time_from_system() * 1000.0), _role_name(), event, details.replace("\"", "'")])
		_log_file.flush()
	if event in ["console", "dash_reaction", "client_correction", "server_dash_reject", "client_dash_rejected_by_server",
			"server_dash_accept", "dash_no_reaction", "spawn", "spawned_self", "server_reject_move", "listen_server_started"]:
		_events.append("%s  %s" % [event.to_upper(), details])
		if _events.size() > 7:
			_events.pop_front()


func _stats_line() -> String:
	var avg := 0.0
	for l in _latencies:
		avg += l
	if not _latencies.is_empty():
		avg /= _latencies.size()
	return "corrections=%d dash_latency_avg_ms=%.1f samples=%d rtt_ms=%.1f sent=%d dropped_out=%d dropped_in=%d" % [
		corrections, avg, _latencies.size(), _rtt, emu.sent, emu.dropped, emu.dropped_in]


# ============================================================================
# World, camera, HUD
# ============================================================================

func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/sky.gdshader")
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.6, 0.75)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	add_child(sun)

	var half := NetSim.ARENA_HALF
	_box(Vector3(0, -0.5, 0), Vector3(half.x * 2 + 12, 1.0, half.y * 2 + 12), Color("4cb860"))
	_box(Vector3(0, -0.02, 0), Vector3(half.x * 2, 0.06, half.y * 2), Color("3a3646"))
	# Painted grid so motion and corrections are easy to read on video.
	for x in range(-int(half.x) + 4, int(half.x), 8):
		_box(Vector3(x, 0.02, 0), Vector3(0.12, 0.02, half.y * 2), Color("57526a"))
	for z in range(-int(half.y) + 4, int(half.y), 8):
		_box(Vector3(0, 0.02, z), Vector3(half.x * 2, 0.02, 0.12), Color("57526a"))
	# Walls: red/white comic kerbs.
	var n := 0
	for x in range(-int(half.x), int(half.x), 4):
		for zs in [-1.0, 1.0]:
			_box(Vector3(x + 2, 0.6, zs * (half.y + 0.5)), Vector3(4, 1.2, 1), Game.RED if n % 2 == 0 else Game.PAPER)
		n += 1
	n = 0
	for z in range(-int(half.y), int(half.y), 4):
		for xs in [-1.0, 1.0]:
			_box(Vector3(xs * (half.x + 0.5), 0.6, z + 2), Vector3(1, 1.2, 4), Game.RED if n % 2 == 0 else Game.PAPER)
		n += 1
	for p: Vector4 in NetSim.PILLARS:
		_box(Vector3(p.x, 1.2, p.y), Vector3(p.z * 2, 2.4, p.w * 2), Game.YELLOW)
		_box(Vector3(p.x, 2.45, p.y), Vector3(p.z * 2 + 0.3, 0.15, p.w * 2 + 0.3), Game.INK)

	_ghost = NetKartView.make_ghost()
	_ghost.visible = false
	add_child(_ghost)
	_cam = Camera3D.new()
	_cam.fov = 55.0
	add_child(_cam)
	_cam.add_child(Toon.ink_overlay())
	_cam.position = Vector3(0, 48, 30)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	_cam.make_current()


func _box(pos: Vector3, size: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = Toon.mat(color)
	mi.position = pos
	add_child(mi)


func _update_camera(delta: float) -> void:
	var target: Node3D = _own_view
	if role == Role.SERVER and cam_follow_client:
		for peer in _players:
			if peer != 1 and get_node_or_null("Kart_%d" % peer):
				target = get_node("Kart_%d" % peer)
				break
	if target == null:
		return
	var focus := target.position
	var want := focus + Vector3(0, 14, 12)
	_cam.position = _cam.position.lerp(want, clampf(delta * 4.0, 0.0, 1.0))
	_cam.look_at(_cam.position + Vector3(0, -14, -12), Vector3.UP)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var stats_panel := Ui.panel(Color(Game.PAPER, 0.92), -6.0, 12.0)
	stats_panel.position = Vector2(16, 16)
	_hud_stats = Ui.label("", 21, Game.INK, Game.FONT_BODY, 0)
	stats_panel.add_child(_hud_stats)
	root.add_child(stats_panel)

	_caption_panel = Ui.panel(Game.RED, 10.0, 12.0)
	_place(_caption_panel, Vector2(0.5, 0.0), 14.0, Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_END)
	_hud_caption = Ui.label("", 34, Game.PAPER, null, 8)
	_caption_panel.add_child(_hud_caption)
	_caption_panel.visible = false
	root.add_child(_caption_panel)

	var ev_panel := Ui.panel(Color(Game.INK, 0.82), 0.0, 10.0)
	_place(ev_panel, Vector2(0.0, 1.0), -52.0, Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_BEGIN, 16.0)
	ev_panel.custom_minimum_size = Vector2(900, 0)
	_hud_events = Ui.label("", 17, Game.PAPER, Game.FONT_BODY, 0)
	ev_panel.add_child(_hud_events)
	root.add_child(ev_panel)

	var keys := Ui.label("W/S drive  A/D steer  SPACE dash  |  F1 console  F2 net profile  F3 dash CSP  F4 move prediction  F6 cooldown cheat  F7 speed cheat  F8 ghost  F9 autodrive  ESC menu",
		17, Game.PAPER, Game.FONT_BODY, 5)
	_place(keys, Vector2(0.0, 1.0), -10.0, Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_BEGIN, 18.0)
	root.add_child(keys)

	_console = LineEdit.new()
	_console.placeholder_text = "NetEmulation.PktLag 100 | net.DashPrediction 0 | cheat.IgnoreCooldown 1 | stats"
	_console.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_console.position = Vector2(0, 0)
	_console.custom_minimum_size = Vector2(0, 44)
	_console.add_theme_font_override("font", Game.FONT_BODY)
	_console.add_theme_font_size_override("font_size", 24)
	_console.visible = false
	_console.text_submitted.connect(func(t: String):
		exec(t)
		_console.clear())
	root.add_child(_console)


## Anchor a control to a point of the screen; it grows away from the edge.
func _place(c: Control, anchor: Vector2, y: float, grow_h: int, grow_v: int, x := 0.0) -> void:
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = x
	c.offset_right = x
	c.offset_top = y
	c.offset_bottom = y
	c.grow_horizontal = grow_h
	c.grow_vertical = grow_v


func _toggle_console() -> void:
	_console.visible = not _console.visible
	if _console.visible:
		_console.grab_focus()
	else:
		_console.release_focus()


func _set_caption(text: String) -> void:
	caption = text
	if _hud_caption:
		_hud_caption.text = text
		_caption_panel.visible = text != ""


func _update_hud() -> void:
	var lines := PackedStringArray()
	match role:
		Role.SERVER:
			lines.append("LISTEN SERVER (authority) + player 1   tick %d" % _server_tick)
			lines.append("NET EMULATION (this peer): %s" % emu.describe())
			for p: ServerPlayer in _players.values():
				lines.append("peer %d  slot %d  ack seq %d  dash ok %d / rejected %d  move-budget rejects %d  input gaps %d" % [
					p.peer, p.slot, p.last_seq, p.dash_ok, p.dash_rejected, p.budget_rejects, p.gaps])
		Role.CLIENT:
			lines.append("CLIENT peer %d - own kart: AUTONOMOUS PROXY" % _my_id)
			lines.append("DASH: %s    MOVE PREDICTION: %s   " % [
				"CLIENT-SIDE PREDICTION" if dash_prediction else "NO PREDICTION (server RPC)", "ON" if move_prediction else "OFF"])
			lines.append("NET EMULATION: %s" % emu.describe())
			lines.append("RTT %s ms   unacked moves %d   corrections %d (last %.2f m)" % [
				"--" if _rtt < 0 else "%.0f" % _rtt, _saved.size(), corrections, last_correction])
			lines.append("last dash press->reaction: %s   rejected by server: %d" % [
				"--" if last_latency < 0 else "%.0f ms" % last_latency, dash_rejected])
			var cheats := PackedStringArray()
			if cheat_ignore_cooldown:
				cheats.append("IGNORE COOLDOWN")
			if cheat_speed_mult != 1.0:
				cheats.append("SPEED x%.1f" % cheat_speed_mult)
			if cheat_double_tick:
				cheats.append("DOUBLE TICK")
			lines.append("CLIENT CHEATS: %s" % ("none" if cheats.is_empty() else ", ".join(cheats)))
			if not _spawned:
				lines.append("waiting for server...")
		_:
			lines.append("NET LAB - choose HOST or JOIN")
	_hud_stats.text = "\n".join(lines)
	_hud_events.text = "\n".join(PackedStringArray(_events)) if not _events.is_empty() else "events will appear here"


# --- lobby ---------------------------------------------------------------------

func _show_lobby() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_lobby = Control.new()
	_lobby.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_lobby)
	var col := VBoxContainer.new()
	col.position = Vector2(80, 220)
	col.custom_minimum_size = Vector2(520, 0)
	col.add_theme_constant_override("separation", 16)
	_lobby.add_child(col)
	col.add_child(Ui.label("NET LAB", 110, Game.YELLOW, null, 18))
	var host := Ui.button("HOST (LISTEN SERVER)", Game.YELLOW, 44)
	host.pressed.connect(func(): start_host())
	col.add_child(host)
	_ip_edit = LineEdit.new()
	_ip_edit.text = "127.0.0.1"
	_ip_edit.add_theme_font_size_override("font_size", 30)
	col.add_child(_ip_edit)
	var join := Ui.button("JOIN AS CLIENT", Game.CYAN, 44)
	join.pressed.connect(func(): start_client(_ip_edit.text))
	col.add_child(join)
	var back := Ui.button("BACK", Game.PAPER, 30)
	back.pressed.connect(func(): Game.main.show_menu())
	col.add_child(back)
	host.grab_focus()


func _hide_lobby() -> void:
	if _lobby:
		_lobby.get_parent().queue_free()
		_lobby = null


# --- capture -------------------------------------------------------------------

func _screenshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)


func _capture(delta: float) -> void:
	if _capture_dir == "":
		return
	_capture_acc += delta
	if _capture_acc < _capture_every:
		return
	_capture_acc -= _capture_every
	var img := get_viewport().get_texture().get_image()
	var path := "%s/f_%d.jpg" % [_capture_dir, int(Time.get_unix_time_from_system() * 1000.0)]
	_capture_n += 1
	_save_tasks.append(WorkerThreadPool.add_task(func(): img.save_jpg(path, 0.85)))
	while not _save_tasks.is_empty() and WorkerThreadPool.is_task_completed(_save_tasks[0]):
		WorkerThreadPool.wait_for_task_completion(_save_tasks.pop_front())
