class_name PlayerController
extends KartController
## Local keyboard / gamepad input.


func update(_kart: Kart, _delta: float) -> void:
	throttle = Input.get_action_strength("accelerate")
	brake = Input.get_action_strength("brake")
	steer = Input.get_axis("steer_left", "steer_right")
	drift = Input.is_action_pressed("drift")
	use_item = Input.is_action_just_pressed("use_item")
	shift_up = Input.is_action_just_pressed("gear_up")
	shift_down = Input.is_action_just_pressed("gear_down")
	# Hold brake or look-back while using an item to throw it behind you.
	use_backwards = Input.is_action_pressed("brake") or Input.is_action_pressed("look_back")
	burst = Input.is_action_just_pressed("energy_burst")
