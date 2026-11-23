class_name KRTyre
## Tyre model ported from kart-royale (src/kart/Tyre.ts, MIT).
## Friction-circle tyre: lateral force from a slip-angle curve, longitudinal
## force from what is left of the budget.

const EPS := 1e-6
## [peakSlip, slideSlip, peakMu, slideMu, longMu, loadSensitivity, nominalLoad]
const FRONT := [0.14, 0.6, 1.68, 1.15, 1.5, 0.22, 1000.0]
const REAR := [0.16, 0.78, 1.95, 1.38, 1.8, 0.2, 1000.0]


static func slip_angle(v_long: float, v_lat: float) -> float:
	return atan2(v_lat, maxf(1.4, absf(v_long)))


static func lateral_mu(slip: float, c: Array) -> float:
	var s := absf(slip)
	if s <= c[0]:
		return c[2] * sin(PI * 0.5 * (s / maxf(EPS, c[0])))
	var k := minf(1.0, (s - c[0]) / maxf(EPS, c[1] - c[0]))
	var e := k * k * (3.0 - 2.0 * k)
	return c[2] + (c[3] - c[2]) * e


static func load_factor(load: float, c: Array) -> float:
	var r := load / maxf(EPS, c[6])
	return clampf(1.0 - c[5] * (r - 1.0), 0.55, 1.4)


## Returns [long, lat, slip_angle, saturation, sliding].
static func solve(c: Array, v_long: float, v_lat: float, load: float, grip_mul: float,
		drive_demand: float, corner_mass: float, dt: float) -> Array:
	if not (load > 0.0) or not is_finite(v_lat) or not is_finite(v_long) or not (corner_mass > 0.0) or not (dt > 0.0):
		return [0.0, 0.0, 0.0, 0.0, false]
	var sa := slip_angle(v_long, v_lat)
	var capacity: float = load * grip_mul * load_factor(load, c)
	var budget: float = capacity * float(c[2])
	var lat_max: float = lateral_mu(sa, c) * capacity
	var lat_needed := (corner_mass * absf(v_lat)) / maxf(dt, EPS)
	var lat := -signf(v_lat) * minf(lat_max, lat_needed)
	var lat_cap: float = budget * 0.95
	lat = clampf(lat, -lat_cap, lat_cap)
	var long_room := sqrt(maxf(0.0, budget * budget - lat * lat))
	var long_max: float = minf(long_room, float(c[4]) * capacity)
	var lng := clampf(drive_demand, -long_max, long_max)
	var saturation := minf(1.0, Vector2(lat, lng).length() / maxf(EPS, budget))
	var sliding: bool = absf(sa) > float(c[0]) * 1.15 and lat_needed > lat_max
	return [lng, lat, sa, saturation, sliding]
