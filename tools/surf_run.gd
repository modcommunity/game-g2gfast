extends Node3D

## Surfs an imported map with the real motor and reports where the ride ends.
##
## [b]The suite's bot stands still and every other probe here asks about geometry.[/b]
## Neither is the thing a player does on a surf map, which is to be carried down a ramp
## by gravity for several seconds -- and a run that dies halfway down one is a bug in
## no assertion's reach, because the ramp is solid, the spawn is fine and the map looks
## right in a screenshot.
##
## So this runs [method DotFpsMotor.simulate] -- the same code the game and the server
## run, with the game's own tunables -- from a point on each ramp, with no input at
## all, and asks the only question that matters: did the player still have speed when
## the clock ran out, or did they come to rest on the ride?
##
##     godot --headless --path . tools/surf_run.tscn -- surf_mesa
##     godot --headless --path . tools/surf_run.tscn -- surf_mesa 40     # 40 runs
##
## A run is STALLED if its horizontal speed falls under [constant STALL_UNITS] while it
## is still touching a ramp. That is exactly "I stop in the middle of them".

const RUNS := 60
const SECONDS := 4.0
const ENTRY_SPEED_UNITS := 350.0    ## roughly a player's own walking entry onto a ramp
const STALL_UNITS := 60.0
const DROP_UNITS := 8.0             ## how far above the ramp a run starts


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if args.size() > 0 else "surf_mesa"
	var runs := int(args[1]) if args.size() > 1 else RUNS

	var manifest_path := "res://maps/imported/%s/%s.json" % [id, id]
	if not FileAccess.file_exists(manifest_path):
		push_error("no such imported map: %s" % manifest_path)
		get_tree().quit(1)
		return

	var map := G2GBspMap.new()
	add_child(map)
	map.build_from_path(manifest_path)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var tunables := G2GMovement.tunables_for(G2GConfig.new())
	# `--iterations N` / `--planes N`: what the slide budget is worth, as a number.
	for a in range(args.size() - 1):
		if args[a] == "--iterations":
			tunables.max_slide_iterations = int(args[a + 1])
		elif args[a] == "--planes":
			tunables.max_slide_planes = int(args[a + 1])
	var body := DotFpsPhysicsBody.for_node(self)
	var motor := DotFpsMotor.new(tunables, body)

	var samples := _ramp_samples(map)
	samples.resize(mini(runs, samples.size()))

	var limit := deg_to_rad(tunables.max_slope_angle)
	var dead_stops := 0
	var worst_stop: Dictionary = {}
	var grounded_on_steep := 0
	var total_ticks := 0
	var stalled := 0
	var carried := 0
	var left_the_ramp := 0
	var by_material: Dictionary = {}
	var step := 1.0 / 128.0
	for sample: Array in samples:
		var state := DotFpsState.new()
		var n: Vector3 = sample[1]
		state.position = sample[0] + n * G2GUnits.to_metres(DROP_UNITS)
		# Entering the way a player does: across the slope, not into it. The downhill
		# direction flattened is the line the ride runs along.
		var along := (Vector3.DOWN - n * n.dot(Vector3.DOWN))
		along.y = 0.0
		if along.length_squared() < 1e-9:
			continue
		state.velocity = along.normalized() * G2GUnits.to_metres(ENTRY_SPEED_UNITS)
		var command := DotFpsCommand.new()

		var outcome := "carried"
		var ticks := int(SECONDS / step)
		for t in range(ticks):
			var before := state.velocity.length()
			motor.simulate(state, command, step)
			# [b]A player is not meant to be STANDING on a surf ramp.[/b] The genre's
			# rule is one number -- anything steeper than max_slope is not ground -- and
			# it is the whole reason a ramp carries a player instead of stopping them.
			# A tick that reports grounded on a face steeper than that is friction
			# applied to a ride, which is a run ending in the middle of a ramp.
			if state.is_grounded() and state.ground_normal.angle_to(Vector3.UP) > limit:
				grounded_on_steep += 1
			total_ticks += 1

			# [b]A dead stop is not a slow-down, and only one thing in the motor does
			# it.[/b] `_slide` zeroes the velocity outright when `_remember_plane`
			# returns PLANE_FULL -- the player has touched
			# [member DotFpsTunables.max_slide_planes] distinct planes inside one tick
			# and the crease search gives up. That is the correct answer in a real
			# five-plane corner and it is what an imported map hands out for free: a
			# curved surf ramp is not one brush, it is a fan of convex hulls whose
			# normals differ by more than the 2.56 degrees `_remember_plane` treats as
			# the same plane, so a hull crossing a few seams in one tick fills the list
			# on open ramp. Losing nearly all speed in a single tick, in the air, is
			# that and nothing else.
			var now := state.velocity.length()
			if not state.is_grounded() and before > 1.0 and now < before * 0.3:
				dead_stops += 1
				if worst_stop.is_empty():
					worst_stop = {
						"at": state.position,
						"from": G2GUnits.to_units(before),
						"to": G2GUnits.to_units(now),
					}
			var speed := G2GUnits.to_units(state.horizontal_speed())
			# Only a stop ON the ride counts. A player who has reached the floor at the
			# bottom and slowed down there has finished the ramp, which is the ramp
			# working.
			if speed < STALL_UNITS and t > int(0.5 / step):
				outcome = "stalled" if _on_a_ramp(state) else "reached the floor"
				break
		match outcome:
			"stalled":
				stalled += 1
				var key: String = sample[2]
				by_material[key] = int(by_material.get(key, 0)) + 1
			"reached the floor":
				left_the_ramp += 1
			_:
				carried += 1

	var total := maxf(1.0, float(stalled + carried + left_the_ramp))
	print("[run] %s: %d runs of %ss -- %d carried to the end, %d reached the floor, %d STALLED ON THE RAMP (%.0f%%)"
		% [id, int(total), SECONDS, carried, left_the_ramp, stalled,
			100.0 * float(stalled) / total])
	print("[run]   %d of %d ticks LOST OVER 70%% OF THEIR SPEED IN ONE TICK, in the air (%.2f%%) -- max_slide_planes=%d"
		% [dead_stops, total_ticks,
			100.0 * float(dead_stops) / maxf(1.0, float(total_ticks)),
			tunables.max_slide_planes])
	if not worst_stop.is_empty():
		print("[run]     first at %s: %d u/s -> %d u/s" % [worst_stop["at"],
			int(worst_stop["from"]), int(worst_stop["to"])])
	print("[run]   %d ticks WEDGED (slide ran out of %d iterations), %d stopped early on a plane already resolved"
		% [motor.stuck_ticks, tunables.max_slide_iterations, motor.duplicate_plane_ticks])
	print("[run]   %d of %d simulated ticks were GROUNDED on a face steeper than %.2f degrees (%.1f%%)"
		% [grounded_on_steep, total_ticks, tunables.max_slope_angle,
			100.0 * float(grounded_on_steep) / maxf(1.0, float(total_ticks))])
	var names := by_material.keys()
	names.sort_custom(func(a, b): return int(by_material[a]) > int(by_material[b]))
	for n: String in names.slice(0, 8):
		print("[run]   %4d  %s" % [int(by_material[n]), n])
	get_tree().quit(0)


## Is the player resting on something steeper than a floor? That is a ramp, and coming
## to rest on one is the bug; coming to rest on a floor is arriving.
func _on_a_ramp(state: DotFpsState) -> bool:
	if not state.is_grounded():
		return false
	return state.ground_normal.angle_to(Vector3.UP) > deg_to_rad(30.0)


func _ramp_samples(map: G2GBspMap) -> Array:
	var mi := map.get_node_or_null("World") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return []
	var out: Array = []
	var surfaces: Array = map.manifest.get("surfaces", [])
	for s in range(mi.mesh.get_surface_count()):
		if s >= surfaces.size():
			continue
		var surface: Dictionary = surfaces[s]
		if str(surface.get("role", "")) != "RAMP":
			continue
		var key := "%s [%s]" % [surface.get("material", "?"), surface.get("role", "?")]
		var arrays := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, indices.size() - 2, 3):
			var normal := normals[indices[i]] + normals[indices[i + 1]] + normals[indices[i + 2]]
			if normal.length_squared() < 1e-9:
				continue
			normal = normal.normalized()
			if normal.y <= 0.01:
				continue
			out.append([(verts[indices[i]] + verts[indices[i + 1]]
				+ verts[indices[i + 2]]) / 3.0, normal, key])
	# [b]Seeded, because every number this prints is a comparison.[/b] `shuffle()` uses
	# the global RNG, so two runs sampled different triangles and the difference between
	# them was mostly which ones -- a sweep over `--iterations` came out 5:1488, 8:2525,
	# 12:1212, which reads as a result and is noise. The sample has to be the same sample
	# for a before and an after to mean anything.
	seed(20250911)
	out.shuffle()
	return out
