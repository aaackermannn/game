extends Node
## Global game state: race settings, roster, input map, fonts and sound hooks.
##
## SOUND: the game ships without audio on purpose. Every gameplay moment that
## should make a noise calls `Game.sfx("event_name", position)`, which emits
## `sound_event`. Connect to it (or edit `sfx`) to plug in your own sounds.
## Event names used: countdown_tick, countdown_go, engine (per-frame via kart),
## drift_start, drift_spark_level, boost, item_pickup, item_roulette,
## item_use, rocket_fire, mine_drop, explosion, shield_up, shield_block,
## energy_pickup, energy_burst, wall_hit, kart_bump, lap, final_lap, finish,
## ui_move, ui_accept, ui_back.

signal sound_event(name: String, position: Vector3)

const FONT_TITLE := preload("res://fonts/Bangers-Regular.ttf")
const FONT_BODY := preload("res://fonts/BarlowCondensed-Bold.ttf")
const FONT_ITALIC := preload("res://fonts/BarlowCondensed-ExtraBoldItalic.ttf")

## Comic palette (ink + bold flats).
const INK := Color("141018")
const PAPER := Color("fff6dc")
const YELLOW := Color("ffd21f")
const RED := Color("ec2b3a")
const BLUE := Color("2b7ff0")
const CYAN := Color("3fe0e8")
const GREEN := Color("4cd35a")
const ORANGE := Color("ff8a1f")
const PURPLE := Color("9a4cf0")

## Racers: original characters. Colors drive the kart livery.
const ROSTER := [
	{"name": "Rico Blaze", "body": Color("ec2b3a"), "trim": Color("fff6dc"), "suit": Color("ffd21f")},
	{"name": "Momo Volt", "body": Color("2b7ff0"), "trim": Color("ffd21f"), "suit": Color("fff6dc")},
	{"name": "Pip Clover", "body": Color("4cd35a"), "trim": Color("141018"), "suit": Color("ff8a1f")},
	{"name": "Juno Fizz", "body": Color("ff5fb4"), "trim": Color("fff6dc"), "suit": Color("2b7ff0")},
	{"name": "Taro Dash", "body": Color("ff8a1f"), "trim": Color("141018"), "suit": Color("3fe0e8")},
	{"name": "Nyx Bolt", "body": Color("9a4cf0"), "trim": Color("3fe0e8"), "suit": Color("fff6dc")},
	{"name": "Bix Turbo", "body": Color("ffd21f"), "trim": Color("ec2b3a"), "suit": Color("141018")},
	{"name": "Ollie Gear", "body": Color("3fe0e8"), "trim": Color("ec2b3a"), "suit": Color("ffd21f")},
]

enum Difficulty { EASY, NORMAL, HARD }

var laps := 3
var bot_count := 7
var difficulty := Difficulty.NORMAL
var player_racer := 0

## Last race results: Array of {name, time, is_player, finished}.
var last_results: Array = []
var main: Node  ## set by main.gd


func _ready() -> void:
	_setup_input()


func sfx(event_name: String, position := Vector3.ZERO) -> void:
	sound_event.emit(event_name, position)


func difficulty_name() -> String:
	return ["Easy", "Normal", "Hard"][difficulty]


static func format_time(t: float) -> String:
	if t < 0.0:
		return "--:--.--"
	var m := int(t / 60.0)
	var s := fmod(t, 60.0)
	return "%d:%05.2f" % [m, s]


static func ordinal(n: int) -> String:
	var suffix := "TH"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1: suffix = "ST"
			2: suffix = "ND"
			3: suffix = "RD"
	return "%d%s" % [n, suffix]


# --- Input -------------------------------------------------------------------

func _setup_input() -> void:
	_action("accelerate", [KEY_W, KEY_UP], [JOY_BUTTON_A], [[JOY_AXIS_TRIGGER_RIGHT, 1.0]])
	_action("brake", [KEY_S, KEY_DOWN], [JOY_BUTTON_B], [[JOY_AXIS_TRIGGER_LEFT, 1.0]])
	_action("steer_left", [KEY_A, KEY_LEFT], [JOY_BUTTON_DPAD_LEFT], [[JOY_AXIS_LEFT_X, -1.0]])
	_action("steer_right", [KEY_D, KEY_RIGHT], [JOY_BUTTON_DPAD_RIGHT], [[JOY_AXIS_LEFT_X, 1.0]])
	_action("drift", [KEY_SPACE, KEY_SHIFT], [JOY_BUTTON_RIGHT_SHOULDER], [])
	_action("use_item", [KEY_E, KEY_J], [JOY_BUTTON_X], [])
	_action("energy_burst", [KEY_R, KEY_K], [JOY_BUTTON_Y], [])
	_action("look_back", [KEY_C], [JOY_BUTTON_LEFT_SHOULDER], [])
	_action("pause", [KEY_ESCAPE, KEY_P], [JOY_BUTTON_START], [])
	_action("restart_race", [KEY_F5], [], [])


func _action(action: String, keys: Array, buttons: Array, axes: Array) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action, 0.25)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)
	for b in buttons:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		InputMap.action_add_event(action, e)
	for a in axes:
		var e := InputEventJoypadMotion.new()
		e.axis = a[0]
		e.axis_value = a[1]
		InputMap.action_add_event(action, e)
