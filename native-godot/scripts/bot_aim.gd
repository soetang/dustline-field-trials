class_name FieldBotAim
extends RefCounted

const Weapons = preload("res://scripts/weapons.gd")

# Shared by both teams. No difficulty bonus against the human, damage reduction,
# wall tracking or guaranteed misses. Cover still blocks the actual bullet ray.
static func higher_aim_allowed(contact_age: float, shooter_speed: float, target_speed: float, distance: float) -> bool:
	return contact_age >= 1.4 and shooter_speed < 0.65 and target_speed < 1.25 and distance < 26

static func aim_height(crouched: bool, higher: bool, sample: float) -> float:
	if higher: return (1.09 if crouched else 1.60) + sample * 0.025
	return (0.72 if crouched else 1.20) + sample * 0.10

static func lateral_error(contact_age: float, target_speed: float, distance: float, sample: float) -> float:
	# Tracking error is sideways, not a bigger vertical lottery that accidentally
	# rewards running targets with more stray headshots.
	var settling := 1.0 - clampf(contact_age / 1.4, 0, 1)
	return tan(deg_to_rad(settling * 0.55 + minf(target_speed, 5.0) * 0.18)) * distance * sample

static func spread(slot: int, contact_age: float, shooter_speed: float, burst_shots: int) -> float:
	var settling := 1.0 - clampf(contact_age / 1.4, 0, 1)
	var degrees: float = 0.60 + Weapons.SPECS[slot].spread + settling * 0.15
	degrees += shooter_speed * 0.23
	degrees += minf(burst_shots, 3) * float(Weapons.SPECS[slot].bloom) * 0.65
	return deg_to_rad(degrees)
