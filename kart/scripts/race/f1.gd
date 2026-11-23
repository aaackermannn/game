class_name F1
## Formula 1 scale for Loop GP. Everything speed-related reads from here, so the
## whole game can be re-tuned in one place.
##
## Targets (real F1): top speed ~330 km/h, 0-100 ~2.6 s, 0-200 ~5 s, 0-300 ~10-11 s,
## traction-limited up to ~150 km/h, aerodynamic downforce that multiplies grip
## and braking with speed. The Sunset Bay circuit was exported 3x longer
## (4.8 km lap) so corner radii match F1 speeds.

const TOP_SPEED := 92.0            # m/s (331 km/h): where drag meets engine power in 8th
const TRACK_SCALE := 3.0           # circuit length scale vs. kart-royale's original
const AERO_DRAG := 0.18            # F = k * v^2 (kart-royale's karts used 0.46 at 30 m/s)
const DOWNFORCE_REF := 55.0        # m/s at which downforce adds DOWNFORCE_GAIN of grip
const DOWNFORCE_GAIN := 0.6
const PROJECTILE_SCALE := 3.2      # items fly ~3x faster so they can catch F1 cars


## Grip / braking multiplier from downforce at speed v (m/s): 1.0 at rest,
## ~1.6 at 200 km/h, ~2.7 at 330 km/h.
static func downforce(v: float) -> float:
	var r := absf(v) / DOWNFORCE_REF
	return 1.0 + DOWNFORCE_GAIN * r * r
