extends Node3D

## Sweeps the player's own hull DOWN a ramp, everywhere, and reports where it stops.
##
## [b][method collision_probe] asks whether a surface is solid; nothing asked whether a
## player can travel along one.[/b] Those are different questions and only the second
## one is what a surf map is: a ride ends where the hull catches on something, and the
## something is routinely geometry that is not the ramp -- a displacement seam, the
## brush next door, a pane standing in the ride. A run that stops halfway down a ramp
## is invisible to every assertion here, because the ramp is solid and the spawn is
## fine and the bot that stands on it for three seconds never moves.
##
##     godot --headless --path . tools/surf_probe.tscn -- surf_mesa
##     godot --headless --path . tools/surf_probe.tscn -- surf_mesa 512
##
## The second argument is how far to sweep, in genre units; the default is roughly the
## distance covered in a quarter of a second at surf speed.

const HULL_RADIUS_UNITS := 16.0
const HULL_HEIGHT_UNITS := 72.0
const SKIN_UNITS := 1.0             # how far off the ramp the hull starts
const SWEEP_UNITS := 256.0
const SAMPLE_LIMIT := 4000
const BLOCKED_BELOW := 0.9          # a sweep that got less than this far is a stop
# How much a contact normal has to oppose the travel before it is a wall rather than
# the ramp's own curvature. cos(70 degrees): a face turned further than that from the
# direction of travel is one a sliding hull is carried along, not stopped by.
const WALL_DOT := 0.34
## How far to lift the hull off the ramp when re-testing a stop, in genre units. The
## smallest lift that clears an obstruction IS its height, and the height is what says
## what made it: a seam between two brushes is a fraction of a unit, a mapper's step is
## a round number of them, and a wall clears at none of these.
const LIFT_STEPS := [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if args.size() > 0 else "surf_mesa"
	var sweep_units := float(args[1]) if args.size() > 1 else SWEEP_UNITS

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

	var samples := _ramp_samples(map)
	var space := get_viewport().world_3d.direct_space_state
	var radius := G2GUnits.to_metres(HULL_RADIUS_UNITS)
	var height := G2GUnits.to_metres(HULL_HEIGHT_UNITS)
	var skin := G2GUnits.to_metres(SKIN_UNITS)
	var sweep := G2GUnits.to_metres(sweep_units)

	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = maxf(height, radius * 2.0 + 0.01)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape

	var clear := 0
	var stuck := 0
	var grazed := 0
	var cleared_at := PackedInt32Array()
	cleared_at.resize(LIFT_STEPS.size())

	var embedded := 0
	var stops: Array[Vector3] = []
	var by_material: Dictionary = {}
	for sample: Array in samples:
		var p: Vector3 = sample[0]
		var n: Vector3 = sample[1]
		# The hull rides with its BOTTOM on the ramp, which is what a player on a
		# 45-degree slope is: standing, not lying along the normal. Lifting along the
		# normal instead puts the capsule inside the ramp on anything steep.
		var centre := p + Vector3.UP * (shape.height * 0.5) + n * skin
		# Steepest descent in the ramp's own plane: the line a surfer is carried along.
		var down := (Vector3.DOWN - n * n.dot(Vector3.DOWN)).normalized()
		if not is_finite(down.x):
			continue
		query.transform = Transform3D(Basis.IDENTITY, centre)
		query.motion = down * sweep
		var hit := space.cast_motion(query)
		if hit.size() != 2:
			continue
		if hit[0] <= 0.0 and hit[1] <= 0.0:
			embedded += 1                       # started inside something
			continue
		if hit[0] >= BLOCKED_BELOW:
			clear += 1
			continue
		# [b]A sweep that stops is not yet a ride that stops.[/b] A surf ramp is curved,
		# and a straight line down a curve leaves the surface and comes back to it a few
		# metres later; a player following it is sliding, not stopping. What ends a run
		# is a face the hull cannot slide along -- one whose normal OPPOSES the travel.
		# So the contact normal is read at the point the sweep stopped, and only a wall
		# counts.
		query.transform = Transform3D(Basis.IDENTITY,
			centre + down * sweep * float(hit[1]))
		var rest := space.get_rest_info(query)
		var key: String = sample[2]
		if rest.is_empty():
			grazed += 1
			continue
		var face: Vector3 = rest.get("normal", Vector3.ZERO)
		if face.dot(down) >= -WALL_DOT:
			grazed += 1
			continue
		stuck += 1
		by_material[key] = int(by_material.get(key, 0)) + 1
		stops.append(centre + down * sweep * float(hit[1]))
		# [b]A wall and a two-unit lip stop a hull the same way and are not the same
		# bug.[/b] Re-run the sweep with the hull lifted clear of the surface: an
		# obstruction that disappears was a step at a seam between two brushes, which
		# is this importer's to fix, and one that survives is geometry the mapper drew.
		for b in range(LIFT_STEPS.size()):
			query.transform = Transform3D(Basis.IDENTITY,
				centre + n * G2GUnits.to_metres(float(LIFT_STEPS[b])))
			var high := space.cast_motion(query)
			if high.size() == 2 and high[0] >= BLOCKED_BELOW:
				cleared_at[b] += 1
				break

	var total := maxf(1.0, float(clear + stuck + grazed + embedded))
	print("[surf] %s: %d ramp samples, %d ran clear, %d slid on the ramp, %d STOPPED DEAD (%.1f%%), %d started embedded"
		% [id, samples.size(), clear, grazed, stuck, 100.0 * float(stuck) / total,
			embedded])
	var names := by_material.keys()
	names.sort_custom(func(a, b): return int(by_material[a]) > int(by_material[b]))
	var lipped := 0
	for c in cleared_at:
		lipped += c
	print("[surf]   of those, %d were a LIP rather than a wall -- lifting the hull cleared them:" % lipped)
	for b in range(LIFT_STEPS.size()):
		if cleared_at[b] > 0:
			print("[surf]     %5d cleared at %s units" % [cleared_at[b], LIFT_STEPS[b]])
	for n: String in names.slice(0, 10):
		print("[surf]   %5d  %s" % [int(by_material[n]), n])
	if args.has("--dump"):
		var f := FileAccess.open("user://surf_stops_%s.txt" % id, FileAccess.WRITE)
		for v in stops:
			f.store_line("%f %f %f" % [v.x, v.y, v.z])
		print("[surf]   wrote %s" % f.get_path_absolute())
	get_tree().quit(0)


## The centre and normal of every triangle on a RAMP surface, thinned to a limit.
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
			var a := verts[indices[i]]
			var b := verts[indices[i + 1]]
			var c := verts[indices[i + 2]]
			var normal := normals[indices[i]] + normals[indices[i + 1]] + normals[indices[i + 2]]
			if normal.length_squared() < 1e-9:
				continue
			normal = normal.normalized()
			if normal.y <= 0.01:
				continue
			out.append([(a + b + c) / 3.0, normal, key])
	# [b]Seeded, because every number this prints is a comparison.[/b] `shuffle()` uses
	# the global RNG, so two runs sampled different triangles and the difference between
	# them was mostly which ones -- a sweep over `--iterations` came out 5:1488, 8:2525,
	# 12:1212, which reads as a result and is noise. The sample has to be the same sample
	# for a before and an after to mean anything.
	seed(20250911)
	out.shuffle()
	return out.slice(0, SAMPLE_LIMIT)
