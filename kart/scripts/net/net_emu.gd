class_name NetEmu
extends RefCounted
## Network emulation for NET LAB, modelled on Unreal's NetEmulation.* console
## variables. Every gameplay message this peer sends or receives passes through
## here: it is held back by the configured lag (+- variance) and unreliable
## messages may be dropped. Reliable messages are never dropped; a "lost"
## reliable message instead arrives one extra round-trip later, which is what a
## retransmission looks like to the game.
##
##   NetEmulation.PktLag <ms>                outgoing delay
##   NetEmulation.PktLagVariance <ms>        outgoing +- jitter
##   NetEmulation.PktLoss <percent>          outgoing loss
##   NetEmulation.PktIncomingLag <ms>        incoming delay
##   NetEmulation.PktIncomingLagVariance <ms>
##   NetEmulation.PktIncomingLoss <percent>
##   NetEmulation.Off

var out_lag := 0.0
var out_var := 0.0
var out_loss := 0.0
var in_lag := 0.0
var in_var := 0.0
var in_loss := 0.0

var sent := 0
var dropped := 0
var received := 0
var dropped_in := 0

var _out: Array = []   # [release_ms, callable]
var _in: Array = []
var _rng := RandomNumberGenerator.new()

const PROFILES := [
	{"name": "NO EMULATION", "cmds": ["NetEmulation.Off"]},
	{"name": "100 ms / 0% loss", "cmds": [
		"NetEmulation.PktLag 100", "NetEmulation.PktLagVariance 0", "NetEmulation.PktLoss 0",
		"NetEmulation.PktIncomingLag 100", "NetEmulation.PktIncomingLagVariance 0", "NetEmulation.PktIncomingLoss 0"]},
	{"name": "175+-25 ms / 5% loss", "cmds": [
		"NetEmulation.PktLag 175", "NetEmulation.PktLagVariance 25", "NetEmulation.PktLoss 5",
		"NetEmulation.PktIncomingLag 175", "NetEmulation.PktIncomingLagVariance 25", "NetEmulation.PktIncomingLoss 5"]},
]


func _init(seed_value := 0) -> void:
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()


func active() -> bool:
	return out_lag > 0.0 or out_var > 0.0 or out_loss > 0.0 or in_lag > 0.0 or in_var > 0.0 or in_loss > 0.0


func describe() -> String:
	if not active():
		return "off"
	return "out %d+-%d ms %d%%  |  in %d+-%d ms %d%%" % [out_lag, out_var, out_loss, in_lag, in_var, in_loss]


## Apply one console command. Returns a human-readable result.
func command(line: String) -> String:
	var parts := line.strip_edges().split(" ", false)
	if parts.is_empty():
		return ""
	var key := parts[0].to_lower()
	var v := float(parts[1]) if parts.size() > 1 else 0.0
	match key:
		"netemulation.off":
			out_lag = 0.0
			out_var = 0.0
			out_loss = 0.0
			in_lag = 0.0
			in_var = 0.0
			in_loss = 0.0
		"netemulation.pktlag": out_lag = maxf(v, 0.0)
		"netemulation.pktlagvariance": out_var = maxf(v, 0.0)
		"netemulation.pktloss": out_loss = clampf(v, 0.0, 100.0)
		"netemulation.pktincominglag": in_lag = maxf(v, 0.0)
		"netemulation.pktincominglagvariance": in_var = maxf(v, 0.0)
		"netemulation.pktincomingloss": in_loss = clampf(v, 0.0, 100.0)
		_:
			return "unknown command: " + parts[0]
	return "%s -> %s" % [line.strip_edges(), describe()]


func apply_profile(index: int) -> void:
	for c in PROFILES[index]["cmds"]:
		command(c)


## Queue an outgoing message. `fn` performs the real rpc_id() call.
func send(fn: Callable, reliable: bool) -> void:
	sent += 1
	var delay := _delay(out_lag, out_var)
	if out_loss > 0.0 and _rng.randf() * 100.0 < out_loss:
		if not reliable:
			dropped += 1
			return
		delay += 2.0 * (out_lag + in_lag) + 50.0  # retransmission after a timeout
	_push(_out, delay, fn)


## Queue an incoming message for local processing.
func receive(fn: Callable, reliable: bool) -> void:
	received += 1
	var delay := _delay(in_lag, in_var)
	if in_loss > 0.0 and _rng.randf() * 100.0 < in_loss:
		if not reliable:
			dropped_in += 1
			return
		delay += 2.0 * (out_lag + in_lag) + 50.0
	_push(_in, delay, fn)


## Call once per frame: delivers everything whose time has come.
func flush() -> void:
	_release(_out)
	_release(_in)


func _delay(lag: float, variance: float) -> float:
	if variance <= 0.0:
		return lag
	return maxf(0.0, lag + _rng.randf_range(-variance, variance))


func _push(q: Array, delay_ms: float, fn: Callable) -> void:
	if delay_ms <= 0.0:
		fn.call()
		return
	q.append([Time.get_ticks_usec() / 1000.0 + delay_ms, fn])


func _release(q: Array) -> void:
	if q.is_empty():
		return
	var now := Time.get_ticks_usec() / 1000.0
	var due: Array = []
	var keep: Array = []
	for e in q:
		if e[0] <= now:
			due.append(e)
		else:
			keep.append(e)
	if due.is_empty():
		return
	q.assign(keep)
	due.sort_custom(func(a, b): return a[0] < b[0])
	for e in due:
		(e[1] as Callable).call()
