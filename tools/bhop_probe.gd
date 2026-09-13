extends Node3D

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GUnits := preload("../game/g2g_units.gd")

## Bunny-hops across a map with the real motor and reports anybody who leaves it.
##
## [b]"I bhop and go through the floor" is the one failure no probe here could see.[/b]
## `collision_probe` drops a hull straight down onto a surface and asks whether it stops,
## which is a question about the geometry; `surf_probe` sweeps along a ramp, which is a
## question about travelling. Neither of them JUMPS, and landing is where a player meets
## the ground snap — the longest and least precise query in the tick, run once per landing
## and therefore once per hop. A bhopper lands three times a second for a whole run.
##
##     godot --headless --path . tools/bhop_probe.tscn -- surf_aquaflow
##     godot --headless --path . tools/bhop_probe.tscn -- surf_aquaflow 30 20
##
## Arguments: map id, how many starts, how many seconds each.

const STARTS := 40
const SECONDS := 12.0
const TICK := 128.0
const ENTRY_SPEED_UNITS := 250.0
const BELOW_UNITS := 96.0    ## how far under a surface counts as through it


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if args.size() > 0 else "surf_aquaflow"
	var starts := int(args[1]) if args.size() > 1 else STARTS
	var seconds := float(args[2]) if args.size() > 2 else SECONDS

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
	var body := DotFpsPhysicsBody.for_node(self)
	var motor := DotFpsMotor.new(tunables, body)

	# The bottom of the map, in genre units. A player below it has left the world
	# whatever else happened; below the surface they started on is the interesting case.
	var bounds: Dictionary = map.manifest.get("bounds", {})
	var mins: Array = bounds.get("min", [0.0, -99999.0, 0.0])
	var floor_min: float = float(mins[1]) if mins.size() > 1 else -99999.0
	var starts_at := _standable(map)
	starts_at.resize(mini(starts, starts_at.size()))

	var tunnelled := 0
	var left_world := 0
	var fine := 0
	var step := 1.0 / TICK
	var worst := {}

	for sample: Array in starts_at:
		var state := DotFpsState.new()
		# A hull's worth above the surface, which is where a spawn puts a player.
		state.position = (sample[0] as Vector3) + Vector3.UP * G2GUnits.to_metres(8.0)
		var floor_y: float = (sample[0] as Vector3).y
		state.velocity = (sample[1] as Vector3) * G2GUnits.to_metres(ENTRY_SPEED_UNITS)

		var height: float = tunables.stand_height
		var command := DotFpsCommand.new()
		# Held, not tapped: `autobhop on` is what the server runs and what the report
		# was recorded under, and a held jump is the input that hits the snap every
		# single landing rather than every other one.
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		command.move = Vector2(0.0, 1.0)
		command.yaw = rad_to_deg(atan2(-(sample[1] as Vector3).x, -(sample[1] as Vector3).z))

		var verdict := "fine"
		var previous_y := state.position.y
		for t in range(int(seconds / step)):
			motor.simulate(state, command, step)

			# [b]There is no overlap test here, and the two that were tried are why.[/b]
			# "Is the player further below the surface they started on than 96 units"
			# reported 50% to 78% and was mostly players running downhill correctly, on
			# a map shaped like a descent. "Is the player's hull inside solid", asked
			# with `intersect_shape`, reported 70% to 75% AND DID NOT MOVE when the motor
			# was changed — because a capsule resting a millimetre above a floor overlaps
			# it too. Shapes have margins; standing on the ground is an overlap.
			#
			# The distinction that matters cannot be made from out here. It is the one
			# [method DotFpsMotor._categorise_ground] already makes and had no way to
			# report — the ground probe found nothing AND the player is in something —
			# and it is counted by [member DotFpsMotor.embedded_ticks] now, which is what
			# this reads at the end instead.
			#
			# Worth the four lines: both of those numbers were large, plausible, and
			# measured nothing at all.

			# And the other way through a floor, which leaves no overlap behind at all:
			# one tick that moves further than a tick can. Terminal velocity at 128 tick
			# is a few units; anything past a hull's height was not fallen, it was
			# skipped.
			var dropped := G2GUnits.to_units(previous_y - state.position.y)
			if dropped > G2GUnits.to_units(height):
				verdict = "tunnelled"
				if worst.is_empty():
					worst = {"at": state.position, "tick": t,
						"how": "%d units in one tick" % int(dropped)}
				break
			previous_y = state.position.y

			if state.position.y < G2GUnits.to_metres(floor_min) - 1.0:
				verdict = "out"
				break
		match verdict:
			"tunnelled": tunnelled += 1
			"out": left_world += 1
			_: fine += 1

	print("[bhop] %s: %d starts, %ds each at %d tick -- %d finished the run, %d TUNNELLED, %d left the world"
		% [id, starts_at.size(), int(seconds), int(TICK), fine, tunnelled, left_world])
	if not worst.is_empty():
		print("[bhop]   first at %s after %d ticks: %s"
			% [worst["at"], int(worst["tick"]), worst["how"]])
	print("[bhop]   motor: %d ticks EMBEDDED IN GEOMETRY, %d of them lifted back out; %d wedged"
		% [motor.embedded_ticks, motor.lifted_ticks, motor.stuck_ticks])
	get_tree().quit(0)


## Centres of upward-facing triangles a player could stand on, with a direction to run.
func _standable(map: G2GBspMap) -> Array:
	var mi := map.get_node_or_null("World") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return []
	var out: Array = []
	var surfaces: Array = map.manifest.get("surfaces", [])
	for s in range(mi.mesh.get_surface_count()):
		if s >= surfaces.size():
			continue
		if str((surfaces[s] as Dictionary).get("role", "")) != "PLATFORM":
			continue
		var arrays := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, indices.size() - 2, 3):
			var n := normals[indices[i]] + normals[indices[i + 1]] + normals[indices[i + 2]]
			if n.length_squared() < 1e-9 or n.normalized().y < 0.9:
				continue
			var a := verts[indices[i]]
			var b := verts[indices[i + 1]]
			var c := verts[indices[i + 2]]
			# A direction along the triangle, so the run goes somewhere rather than into
			# the nearest wall every time.
			var along := (b - a)
			along.y = 0.0
			if along.length_squared() < 1e-9:
				continue
			out.append([(a + b + c) / 3.0, along.normalized()])
	seed(20250911)
	out.shuffle()
	return out
