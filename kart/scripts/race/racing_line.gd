class_name RacingLine
extends RefCounted
## Racing line + speed profile ported from kart-royale (src/game/AI.ts RacingLine, MIT).
## Nodes every ~4 m: the centreline is relaxed toward the shortest path inside the
## road, pulled to the inside of bends, given late apexes, then a speed profile is
## solved from lateral grip (helped by banking) and braking distance.

const NODE_DS := 4.0
const EDGE_MARGIN := 2.0
const RELAX_PASSES := 320
const RELAX_RATE := 0.32
const LATE_APEX_SHIFT := 13.0
const GRAVITY := 20.0
const A_LAT := 12.6
const A_BRAKE := 11.5
const BASE_TOP_SPEED := 30.0

var count := 0
var ds := 0.0
var length := 0.0
var px := PackedFloat32Array()
var py := PackedFloat32Array()
var pz := PackedFloat32Array()
var cx := PackedFloat32Array()
var cy := PackedFloat32Array()
var cz := PackedFloat32Array()
var bx := PackedFloat32Array()
var by := PackedFloat32Array()
var bz := PackedFloat32Array()
var off := PackedFloat32Array()
var half := PackedFloat32Array()
var bank := PackedFloat32Array()
var curv := PackedFloat32Array()
var speed := PackedFloat32Array()


func build(track: SunsetTrack) -> void:
	length = track.length
	var n := maxi(64, roundi(length / NODE_DS))
	count = n
	ds = length / n
	for arr in [px, py, pz, cx, cy, cz, bx, by, bz, off, half, bank, curv, speed]:
		arr.resize(n)
		arr.fill(0.0)
	for i in n:
		var s := track.sample(float(i) / n)
		var p: Vector3 = s["pos"]
		var b: Vector3 = s["binormal"]
		cx[i] = p.x
		cy[i] = p.y
		cz[i] = p.z
		bx[i] = b.x
		by[i] = b.y
		bz[i] = b.z
		half[i] = s["half"]
		bank[i] = s["bank"]
	var ck := PackedFloat32Array()
	ck.resize(n)
	for i in n:
		ck[i] = _turn(cx, cz, i)
	var lim := PackedFloat32Array()
	lim.resize(n)
	for i in n:
		lim[i] = maxf(0.5, half[i] - EDGE_MARGIN)
	for _pass in RELAX_PASSES:
		for i in n:
			var a := posmod(i - 1, n)
			var b := (i + 1) % n
			var mx := (cx[a] + bx[a] * off[a] + cx[b] + bx[b] * off[b]) * 0.5 - cx[i]
			var my := (cy[a] + by[a] * off[a] + cy[b] + by[b] * off[b]) * 0.5 - cy[i]
			var mz := (cz[a] + bz[a] * off[a] + cz[b] + bz[b] * off[b]) * 0.5 - cz[i]
			var want := mx * bx[i] + my * by[i] + mz * bz[i]
			off[i] = clampf(off[i] + (want - off[i]) * RELAX_RATE, -lim[i], lim[i])
	for i in n:
		var inside := signf(ck[i]) * minf(1.0, absf(ck[i]) * 150.0) * half[i] * 0.5
		off[i] = clampf(off[i] + (inside - off[i]) * 0.24, -lim[i], lim[i])
	var shift := maxi(1, roundi(LATE_APEX_SHIFT / ds))
	var src := off.duplicate()
	for i in n:
		var a := posmod(i - 1, n)
		var b := (i + 1) % n
		var bend := absf(src[a] - 2.0 * src[i] + src[b]) / ds
		var w := minf(1.0, bend * 26.0) * 0.55
		var j := posmod(i - shift, n)
		off[i] = clampf(src[i] + (src[j] - src[i]) * w, -lim[i], lim[i])
	for _pass in 12:
		for i in n:
			off[i] = clampf(off[i] * 0.6 + (off[posmod(i - 1, n)] + off[(i + 1) % n]) * 0.2, -lim[i], lim[i])
	for i in n:
		px[i] = cx[i] + bx[i] * off[i]
		py[i] = cy[i] + by[i] * off[i]
		pz[i] = cz[i] + bz[i] * off[i]
	for i in n:
		curv[i] = _turn(px, pz, i)
	var srcc := curv.duplicate()
	for i in n:
		var acc := 0.0
		for k in range(-2, 3):
			acc += srcc[posmod(i + k, n)]
		curv[i] = acc / 5.0
	var v_cap := BASE_TOP_SPEED * 1.14
	for i in n:
		var k := absf(curv[i])
		var help := -signf(curv[i]) * bank[i]
		var a_lat := maxf(4.0, A_LAT + GRAVITY * sin(clampf(help, -0.45, 0.45)) * 0.85)
		speed[i] = minf(v_cap, sqrt(a_lat / k)) if k > 1e-5 else v_cap
	for _pass in 2:
		for i in range(n - 1, -1, -1):
			var j := (i + 1) % n
			speed[i] = minf(speed[i], sqrt(speed[j] * speed[j] + 2.0 * A_BRAKE * ds))


## Signed turn per metre at node i (kart-royale's discrete curvature).
func _turn(xs: PackedFloat32Array, zs: PackedFloat32Array, i: int) -> float:
	var n := xs.size()
	var a := posmod(i - 1, n)
	var b := (i + 1) % n
	var v1 := Vector2(xs[i] - xs[a], zs[i] - zs[a])
	var v2 := Vector2(xs[b] - xs[i], zs[b] - zs[i])
	var l1 := maxf(v1.length(), 1e-4)
	var l2 := maxf(v2.length(), 1e-4)
	var t1 := v1 / l1
	var t2 := v2 / l2
	return (2.0 * atan2(t1.x * t2.y - t1.y * t2.x, t1.dot(t2))) / (l1 + l2)


func index(d: float) -> int:
	return posmod(int(floorf(d / length * count)), count)


func point(d: float) -> Vector3:
	var f := fposmod(d / length * count, count)
	var i := int(f) % count
	var j := (i + 1) % count
	var u := f - floorf(f)
	return Vector3(lerpf(px[i], px[j], u), lerpf(py[i], py[j], u), lerpf(pz[i], pz[j], u))


func offset_at(d: float) -> float:
	var f := fposmod(d / length * count, count)
	var i := int(f) % count
	return lerpf(off[i], off[(i + 1) % count], f - floorf(f))


func speed_at(d: float) -> float:
	return speed[index(d)]


func curv_at(d: float) -> float:
	return curv[index(d)]


func min_speed(d: float, span: float) -> float:
	var steps := maxi(1, roundi(span / ds))
	var i0 := index(d)
	var m := INF
	for s in steps + 1:
		m = minf(m, speed[(i0 + s) % count])
	return m


func peak_curv(d: float, span: float) -> float:
	var steps := maxi(1, roundi(span / ds))
	var i0 := index(d)
	var best := 0.0
	for s in steps + 1:
		var c := curv[(i0 + s) % count]
		if absf(c) > absf(best):
			best = c
	return best


func lateral_of(p: Vector3, t: float) -> float:
	var i := index(t * length)
	return (p.x - cx[i]) * bx[i] + (p.y - cy[i]) * by[i] + (p.z - cz[i]) * bz[i]
