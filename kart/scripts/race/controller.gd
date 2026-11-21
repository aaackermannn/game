class_name KartController
extends RefCounted
## Input source for a kart. The kart only reads these fields, so a player,
## a bot, a replay or a network peer (UDP server snapshots later) can drive it.

var throttle := 0.0   # 0..1
var brake := 0.0      # 0..1 (also reverse)
var steer := 0.0      # -1 left .. +1 right
var drift := false    # held
var use_item := false # pressed this frame
var burst := false    # pressed this frame
var use_backwards := false  # throw the item behind instead of ahead


func update(_kart: Kart, _delta: float) -> void:
	pass
