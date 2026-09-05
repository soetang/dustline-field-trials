class_name FieldCombat
extends RefCounted

## Round-local facts only: no UI contact follows an unseen attacker.
var game: Node3D
var exchanges: Dictionary = {}
var incoming: Array[Dictionary] = []
var death_report: Dictionary = {}
var kill_until := 0.0

func reset() -> void:
	exchanges.clear()
	incoming.clear()
	death_report.clear()
	kill_until = 0

func key(attacker: Node3D, victim: Node3D) -> String:
	return "%d:%d" % [attacker.get_instance_id(), victim.get_instance_id()]

func record(victim: Node3D, attacker: Node3D, damage: float) -> void:
	var id := key(attacker, victim)
	var entry: Dictionary = exchanges.get(id, {"damage": 0.0, "hits": 0})
	entry.damage += minf(victim.health, maxf(0, damage))
	entry.hits += 1
	exchanges[id] = entry
	if victim == game.player:
		incoming.push_front({"from": attacker.global_position, "until": game.elapsed + 0.85})
		if incoming.size() > 4: incoming.pop_back()

func on_kill(victim: Node3D, attacker: Node3D, headshot: bool) -> void:
	if attacker == game.player: kill_until = game.elapsed + 0.3
	if victim != game.player: return
	var received: Dictionary = exchanges.get(key(attacker, victim), {"damage": 0.0, "hits": 0})
	var dealt: Dictionary = exchanges.get(key(victim, attacker), {"damage": 0.0, "hits": 0})
	death_report = {"killer": game.actor_name(attacker), "slot": attacker.slot, "headshot": headshot,
		"received": received.damage, "received_hits": received.hits, "dealt": dealt.damage, "dealt_hits": dealt.hits, "until": game.elapsed + 6.0}

func tick() -> void:
	while not incoming.is_empty() and incoming.back().until <= game.elapsed: incoming.pop_back()
	while not game.kill_feed.is_empty() and game.kill_feed.back().until <= game.elapsed: game.kill_feed.pop_back()

static func bearing(at: Vector3, camera: Camera3D) -> Vector2:
	var delta := at - camera.global_position
	# Use yaw only: looking up/down must not flip a front/back damage cue.
	var forward := -camera.global_basis.z
	forward.y = 0
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	return Vector2(delta.dot(right), -delta.dot(forward)).normalized()
