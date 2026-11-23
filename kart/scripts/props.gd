class_name Props
## Model factory. Loads Blender-made .glb files from res://assets/models/ and
## converts their materials to comic toon materials. If a model is missing, a
## simple primitive stand-in is built so the game always runs.
##
## Kart model contract (kart.glb): nodes named Body, WheelFL, WheelFR, WheelRL,
## WheelRR, Pilot (with child Head). Materials whose names contain
## livery_body / livery_trim / pilot_suit / pilot_helmet are recolored per racer.

const MODEL_DIR := "res://assets/models/"
const KART_ROYALE_SCALE := 1.0  # true kart-royale size, so physics and model match


static func _load(model_name: String) -> Node3D:
	var path := MODEL_DIR + model_name + ".glb"
	if ResourceLoader.exists(path):
		var scene: PackedScene = load(path)
		if scene:
			return scene.instantiate() as Node3D
	return null


static func make(model_name: String) -> Node3D:
	var n := _load(model_name)
	if n:
		Toon.apply(n)
		return n
	return _fallback(model_name)


## Kart + driver for roster slot `index`. Prefers the kart-royale export
## (assets/models/kart_royale/kart_<index>.glb, livery baked in), then the
## Blender kart.glb (recoloured per racer), then primitives.
static func make_kart(racer: Dictionary, index := -1) -> Node3D:
	if index >= 0:
		var kr := _load("kart_royale/kart_%d" % index)
		if kr:
			Toon.apply(kr)
			kr.scale = Vector3.ONE * KART_ROYALE_SCALE
			return kr
	var recolor := {
		"livery_body": racer["body"],
		"livery_trim": racer["trim"],
		"pilot_suit": racer["suit"],
		"pilot_helmet": racer["body"],
	}
	var n := _load("kart")
	if n:
		Toon.apply(n, recolor)
		return n
	return _fallback_kart(racer)


# --- Primitive stand-ins ---------------------------------------------------------

static func _mi(mesh: Mesh, color: Color, pos := Vector3.ZERO, node_name := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = Toon.mat(color)
	mi.position = pos
	if node_name != "":
		mi.name = node_name
	return mi


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func _cyl(r_top: float, r_bot: float, h: float, segs := 12) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = segs
	return c


static func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 16
	s.rings = 8
	return s


static func _fallback_kart(racer: Dictionary) -> Node3D:
	var root := Node3D.new()
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	body.add_child(_mi(_box(Vector3(1.0, 0.45, 2.6)), racer["body"], Vector3(0, 0.45, 0)))
	body.add_child(_mi(_box(Vector3(2.0, 0.12, 0.5)), racer["body"], Vector3(0, 0.3, -1.45)))
	body.add_child(_mi(_box(Vector3(1.8, 0.12, 0.5)), racer["trim"], Vector3(0, 1.15, 1.25)))
	body.add_child(_mi(_box(Vector3(0.3, 0.8, 0.2)), Game.INK, Vector3(0, 0.75, 1.2)))
	var tire := _cyl(0.42, 0.42, 0.45)
	for w in [["WheelFL", Vector3(-0.95, 0.42, -0.95)], ["WheelFR", Vector3(0.95, 0.42, -0.95)],
			["WheelRL", Vector3(-1.0, 0.46, 0.9)], ["WheelRR", Vector3(1.0, 0.46, 0.9)]]:
		var pivot := Node3D.new()
		pivot.name = w[0]
		pivot.position = w[1]
		var t := _mi(tire, Color("2a2630"))
		t.rotation.z = PI * 0.5
		pivot.add_child(t)
		root.add_child(pivot)
	var pilot := Node3D.new()
	pilot.name = "Pilot"
	pilot.position = Vector3(0, 0.75, 0.15)
	pilot.add_child(_mi(_sphere(0.3), racer["suit"], Vector3(0, 0.15, 0)))
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0.75, 0)
	head.add_child(_mi(_sphere(0.45), racer["body"]))
	head.add_child(_mi(_box(Vector3(0.6, 0.2, 0.1)), Color("9fe6ff"), Vector3(0, 0.0, -0.42)))
	pilot.add_child(head)
	root.add_child(pilot)
	return root


static func _fallback(model_name: String) -> Node3D:
	var root := Node3D.new()
	match model_name:
		"palm":
			root.add_child(_mi(_cyl(0.18, 0.3, 6.0, 8), Color("b07a45"), Vector3(0, 3, 0)))
			for i in 6:
				var leaf := _mi(_box(Vector3(0.7, 0.12, 3.2)), Color("3fb34a"), Vector3(0, 6.0, 0))
				leaf.rotation = Vector3(0.35, TAU * i / 6.0, 0)
				leaf.position += Vector3(sin(TAU * i / 6.0), -0.3, cos(TAU * i / 6.0)) * 1.2
				root.add_child(leaf)
		"bush":
			root.add_child(_mi(_sphere(1.0), Color("3fa94a"), Vector3(0, 0.5, 0)))
			root.add_child(_mi(_sphere(0.7), Color("54c35a"), Vector3(0.8, 0.4, 0.3)))
		"rock":
			var r := _mi(_sphere(1.0), Color("c08a5a"), Vector3(0, 0.3, 0))
			r.scale = Vector3(1.3, 0.8, 1.0)
			root.add_child(r)
		"tires":
			for i in 3:
				root.add_child(_mi(_cyl(0.55, 0.55, 0.35), Color("2a2630") if i != 1 else Color("ec2b3a"), Vector3(0, 0.18 + i * 0.36, 0)))
		"gantry":
			for x in [-11.0, 11.0]:
				root.add_child(_mi(_box(Vector3(1.0, 7.0, 1.0)), Color("ec2b3a"), Vector3(x, 3.5, 0)))
			root.add_child(_mi(_box(Vector3(23.0, 1.6, 1.2)), Color("ffd21f"), Vector3(0, 7.2, 0)))
		"grandstand":
			for i in 5:
				root.add_child(_mi(_box(Vector3(22.0, 0.8, 2.0)), Color("d8d2c4"), Vector3(0, 0.4 + i * 0.8, 2.0 * i)))
			root.add_child(_mi(_box(Vector3(23.0, 0.4, 11.0)), Color("ffd21f"), Vector3(0, 7.0, 4.0)))
		"lighthouse":
			root.add_child(_mi(_cyl(1.6, 2.4, 14.0), Color("fff6dc"), Vector3(0, 7, 0)))
			root.add_child(_mi(_cyl(1.75, 2.1, 3.0), Color("ec2b3a"), Vector3(0, 5, 0)))
			root.add_child(_mi(_cyl(1.5, 1.65, 3.0), Color("ec2b3a"), Vector3(0, 11, 0)))
			root.add_child(_mi(_sphere(1.6), Color("ffd21f"), Vector3(0, 15, 0)))
		"item_box":
			root.add_child(_mi(_box(Vector3(1.4, 1.4, 1.4)), Color("ffd21f")))
		"rocket":
			var b := _mi(_cyl(0.22, 0.22, 1.2), Color("ec2b3a"))
			b.rotation.x = PI * 0.5
			root.add_child(b)
			var nose := _mi(_cyl(0.0, 0.22, 0.5), Color("fff6dc"), Vector3(0, 0, -0.85))
			nose.rotation.x = -PI * 0.5
			root.add_child(nose)
		"bouncer":
			root.add_child(_mi(_sphere(0.42), Color("3fe0e8")))
			var band := _mi(_cyl(0.43, 0.43, 0.16, 16), Color("ffd21f"))
			root.add_child(band)
		"kaboom":
			root.add_child(_mi(_sphere(0.45), Color("ec2b3a")))
			root.add_child(_mi(_cyl(0.12, 0.12, 0.18), Color("2a2630"), Vector3(0, 0.48, 0)))
			root.add_child(_mi(_sphere(0.1), Color("ffd21f"), Vector3(0.1, 0.7, 0)))
		"mine":
			root.add_child(_mi(_sphere(0.55), Color("2a2630"), Vector3(0, 0.45, 0)))
			root.add_child(_mi(_cyl(0.06, 0.06, 0.5), Color("ffd21f"), Vector3(0, 1.05, 0)))
		_:
			root.add_child(_mi(_box(Vector3.ONE), Color.MAGENTA))
	return root
