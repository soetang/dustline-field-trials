class_name FieldBotAim
extends RefCounted

const Weapons = preload("res://scripts/weapons.gd")

# Shared by both teams. No difficulty bonus against the human, damage reduction,
# wall tracking or guaranteed misses. Cover still blocks the actual bullet ray.
static func higher_aim_allowed(contact_age: float, shooter_speed: float, target_speed: float, distance: float) -> bool:
	return contact_age >= 1.4 and shooter_speed < 0.65 and target_speed < 1.25 and distance < 26

static func aim_height(crouched: bool, higher: bool, sample: float) -> float:
	if higher: return (1.09 if crouched else 1.60) + sample * 0.025
	return (0.56 if crouched else 1.0) + sample * 0.065

static func aim_point(from: Vector3,feet: Vector3,crouched: bool,higher: bool,sample: float) -> Vector3:
	var height := aim_height(crouched,higher,sample)
	# A descending ray hits the front of the capsule before reaching its centre.
	# Compensate for that visible surface; aiming through an upper torso from a
	# nearby ledge must not silently turn body intent into a top-of-head hit.
	var distance := maxf(Vector2(from.x-feet.x,from.z-feet.z).length(),0.5)
	var slope := clampf((from.y-feet.y-height)/distance,0,1.5)
	return feet + Vector3.UP*(height-slope*0.28)

static func lateral_error(contact_age: float, target_speed: float, distance: float, sample: float) -> float:
	# Tracking error is sideways, not a bigger vertical lottery that accidentally
	# rewards running targets with more stray headshots.
	var settling := 1.0 - clampf(contact_age / 1.4, 0, 1)
	return tan(deg_to_rad(settling * 1.10 + minf(target_speed, 5.0) * 0.18)) * distance * sample

static func vertical_scale(higher: bool) -> float:
	# Body-focused bursts miss sideways more often than upward into the head.
	# Keep true ray hits and the shared damage rules; this is not hit suppression.
	return 1.0 if higher else 0.50

static func spread(slot: int, contact_age: float, shooter_speed: float, burst_shots: int) -> float:
	var settling := 1.0 - clampf(contact_age / 1.4, 0, 1)
	var degrees: float = 0.60 + Weapons.SPECS[slot].spread + settling * 0.15
	degrees += shooter_speed * 0.23
	degrees += minf(burst_shots, 3) * float(Weapons.SPECS[slot].bloom) * 0.65
	return deg_to_rad(degrees)
