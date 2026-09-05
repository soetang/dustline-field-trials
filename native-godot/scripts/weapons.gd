class_name FieldWeapons
extends RefCounted

const SPECS := [
	{"name": "M4 / CARBINE", "model": "m4", "mag": 30, "damage": 29.0, "interval": 0.092, "reload": 2.35, "spread": 0.20, "bloom": 0.075, "kick": 0.43, "speed": 0.94, "price": 2900},
	{"name": "AK / RIFLE", "model": "ak", "mag": 30, "damage": 35.0, "interval": 0.105, "reload": 2.55, "spread": 0.25, "bloom": 0.105, "kick": 0.62, "speed": 0.92, "price": 2700},
	{"name": "AWP / PRECISION", "model": "awp", "mag": 10, "damage": 100.0, "interval": 1.35, "reload": 3.25, "spread": 0.055, "bloom": 0.06, "kick": 1.35, "speed": 0.78, "price": 4750},
	{"name": "DEAGLE / SIDEARM", "model": "deagle", "mag": 7, "damage": 52.0, "interval": 0.24, "reload": 1.85, "spread": 0.36, "bloom": 0.28, "kick": 1.05, "speed": 1.0, "price": 700},
]

static func spread(slot: int, speed: float, airborne: bool, aimed: bool, crouched: bool, heat: float) -> float:
	var spec: Dictionary = SPECS[slot]
	var degrees: float = spec.spread + speed * (0.47 if slot == 2 else 0.25)
	degrees += minf(heat, 12.0) * float(spec.bloom)
	if airborne: degrees += 3.2
	if slot == 2 and not aimed: degrees += 3.2
	if aimed: degrees *= 0.68
	if crouched: degrees *= 0.78
	return deg_to_rad(degrees)

static func kick(slot: int, shot: int) -> Vector2:
	var spec: Dictionary = SPECS[slot]
	return Vector2(deg_to_rad(spec.kick), deg_to_rad(sin(float(shot) * 1.7) * float(spec.kick) * minf(0.75, shot * 0.09)))

static func direction_with_spread(direction: Vector3, radians: float, rng: RandomNumberGenerator) -> Vector3:
	var right := direction.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.1: right = Vector3.RIGHT
	var up := right.cross(direction).normalized()
	var angle := rng.randf() * TAU
	var radius := sqrt(rng.randf()) * tan(radians)
	return (direction + right * cos(angle) * radius + up * sin(angle) * radius).normalized()
