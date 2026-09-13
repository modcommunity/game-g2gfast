extends SceneTree

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GUnits := preload("../game/g2g_units.gd")

## Is every spawn point on an imported map somewhere a player can actually be?
##
## [b]"I get stuck when I spawn" is a question no existing check asks.[/b]
## `headless_imported` asserts that the MAIN spawn is somewhere a player can stand,
## which is one point out of however many the .bsp carried — and a spawn is not a
## screenshot, a manifest value or a collision percentage, so nothing else here can see
## a bad one. A player put inside a brush is stuck there until they notice a respawn
## key, and the map looks perfect from every other angle.
##
##     godot --headless --path . --script res://tools/spawn_check.gd
##     godot --headless --path . --script res://tools/spawn_check.gd -- surf_aquaflow

const LIFT_UNITS := 4.0     ## a spawn is a point on the floor; a player stands above it

## How far up to look for a position that IS clear, so a hit can be told from a margin.
##
## [b]An overlap test alone proves nothing.[/b] Shapes have collision margins, so a
## capsule resting a millimetre above a floor overlaps it — "is the player in solid"
## answers yes for everybody standing anywhere, and a probe built on it reports 70% of a
## map as broken. What separates a real bad spawn from a margin is whether lifting helps:
## a point that is clear at four units and not at one was never inside anything, and a
## point still solid a whole hull higher is inside a brush.
const PROOF_UNITS := 80.0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var ids := PackedStringArray()
	if args.size() > 0:
		ids.append(args[0])
	else:
		var dir := DirAccess.open("res://maps/imported")
		if dir != null:
			for name in dir.get_directories():
				if FileAccess.file_exists("res://maps/imported/%s/%s.json" % [name, name]):
					ids.append(name)

	var tunables := G2GMovement.tunables_for(G2GConfig.new())
	var bad_total := 0
	var checked_total := 0

	for id in ids:
		var root := Node3D.new()
		root.name = "Probe_%s" % id
		get_root().add_child(root)

		var map := G2GBspMap.new()
		root.add_child(map)
		map.build_from_path("res://maps/imported/%s/%s.json" % [id, id])

		await physics_frame
		await physics_frame

		var body := DotFpsPhysicsBody.for_node(root)
		var points := _spawn_points(map)
		var bad := PackedStringArray()

		for entry: Array in points:
			var at: Vector3 = entry[0]
			# Where the player's CENTRE goes: a spawn names the floor, and the hull
			# stands on it.
			var centre: Vector3 = at + Vector3.UP * (float(tunables.stand_height) * 0.5
				+ G2GUnits.to_metres(LIFT_UNITS))
			if not body.overlaps(centre, float(tunables.stand_height), float(tunables.radius)):
				continue

			# How far up it takes to get clear, which is the number that means something.
			var clear_at := -1.0
			var lift := LIFT_UNITS * 2.0
			while lift <= PROOF_UNITS:
				var higher: Vector3 = at + Vector3.UP * (float(tunables.stand_height) * 0.5
					+ G2GUnits.to_metres(lift))
				if not body.overlaps(higher, float(tunables.stand_height),
						float(tunables.radius)):
					clear_at = lift
					break
				lift *= 2.0

			if clear_at < 0.0:
				bad.append("%s at %s — still solid %d units up" % [entry[1], at, int(PROOF_UNITS)])
			else:
				bad.append("%s at %s — clear only %d units up" % [entry[1], at, int(clear_at)])

		checked_total += points.size()
		bad_total += bad.size()
		print("[spawn] %-18s %d points, %d INSIDE SOLID" % [id, points.size(), bad.size()])
		for line in bad:
			print("[spawn]     %s" % line)

		root.queue_free()
		await process_frame

	print("[spawn] %d points checked, %d inside solid" % [checked_total, bad_total])
	quit(0)


## Every place this map can put a player: the main spawn, the per-track spawns, and the
## destination of every zone that teleports one.
func _spawn_points(map: G2GBspMap) -> Array:
	var out: Array = []
	var manifest := map.manifest

	var spawn: Dictionary = manifest.get("spawn", {})
	if spawn.has("origin"):
		out.append([_vec(spawn["origin"]), "main spawn"])

	for entry: Variant in manifest.get("spawns", []):
		if entry is Dictionary and (entry as Dictionary).has("origin"):
			out.append([_vec((entry as Dictionary)["origin"]),
				"spawn %s" % str((entry as Dictionary).get("track", "?"))])

	for entry: Variant in manifest.get("zones", []):
		if not (entry is Dictionary):
			continue
		var zone: Dictionary = entry
		if zone.has("destination"):
			out.append([_vec(zone["destination"]),
				"%s destination" % str(zone.get("kind", "zone"))])

	return out


func _vec(value: Variant) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		return Vector3(float(a[0]), float(a[1]), float(a[2])) * G2GUnits.METRES_PER_UNIT
	return Vector3.ZERO
