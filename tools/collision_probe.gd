extends Node3D

const G2GBspMap := preload("../game/g2g_bsp_map.gd")
const G2GUnits := preload("../game/g2g_units.gd")

## Drops the player's own hull onto an imported map, everywhere, and counts what it
## falls through.
##
## [b]The suite drops one bot on one spawn, and that is one point of a map.[/b] It is
## the check that exists because a map with no collider is a map a player falls out of,
## and it passed for years against a collider that was missing most of itself -- the
## spawn happened to be one of the places the drawn geometry did cover. What nothing
## asked was whether the rest of the map was solid.
##
## So this asks. It takes the centre of every upward-facing triangle in the map, lifts a
## capsule of the genre's hull above it, sweeps it down, and reports the ones that do
## not land. A brush a player clips through is one of those, and there is no assertion
## that finds it because the failure is a property of the geometry rather than of the
## code.
##
##     godot --headless --path . tools/collision_probe.tscn -- surf_beginner2
##     godot --headless --path . tools/collision_probe.tscn -- surf_beginner2 --trimesh
##
## `--trimesh` strips the manifest's collision block before building, so the map falls
## back to `create_trimesh_collision()` over the drawn mesh. That is what this importer
## did before there was a brush reader, and running the two against each other is the
## only way to say what the change is worth in a number.

const HULL_RADIUS_UNITS := 16.0     # the genre's 32-unit-wide player
const HULL_HEIGHT_UNITS := 72.0
const DROP_UNITS := 64.0            # how far above a surface the hull starts
const SAMPLE_LIMIT := 4000


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if args.size() > 0 else "surf_beginner2"
	var trimesh := args.has("--trimesh")

	var manifest_path := "res://maps/imported/%s/%s.json" % [id, id]
	if not FileAccess.file_exists(manifest_path):
		push_error("no such imported map: %s" % manifest_path)
		get_tree().quit(1)
		return

	var path := manifest_path
	if trimesh:
		# The fallback path, reached by taking the collision block away. Written to
		# user:// rather than over the map, because a probe that edits the thing it is
		# probing is a probe nobody can run twice.
		var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		doc.erase("collision")
		var dir := "user://probe/%s" % id
		DirAccess.make_dir_recursive_absolute(dir)
		FileAccess.open("%s/%s.json" % [dir, id], FileAccess.WRITE).store_string(
			JSON.stringify(doc))
		# The .bin and the textures stay where they are; only the manifest moves, so the
		# map has to be told where its own directory is. Copy the binary across.
		var blob := FileAccess.get_file_as_bytes("res://maps/imported/%s/%s.bin" % [id, id])
		FileAccess.open("%s/%s.bin" % [dir, id], FileAccess.WRITE).store_buffer(blob)
		path = "%s/%s.json" % [dir, id]

	var map := G2GBspMap.new()
	add_child(map)
	map.build_from_path(path)

	await get_tree().physics_frame
	await get_tree().physics_frame

	var points := _sample_points(map)
	var space := get_viewport().world_3d.direct_space_state
	var radius := G2GUnits.to_metres(HULL_RADIUS_UNITS)
	var height := G2GUnits.to_metres(HULL_HEIGHT_UNITS)
	var drop := G2GUnits.to_metres(DROP_UNITS)

	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = maxf(height, radius * 2.0 + 0.01)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape

	var caught := 0
	var through := 0
	var by_material: Dictionary = {}
	for sample: Array in points:
		var p: Vector3 = sample[0]
		# Start a hull's worth above the surface and sweep down twice that far. A
		# surface that is solid stops it; one that is not is a hole in the map.
		var from := p + Vector3.UP * (drop + shape.height * 0.5)
		query.transform = Transform3D(Basis.IDENTITY, from)
		var motion := Vector3.DOWN * (drop * 2.0 + shape.height)
		query.motion = motion
		var hit := space.cast_motion(query)
		if hit.size() == 2 and hit[0] < 1.0:
			caught += 1
		else:
			through += 1
			by_material[sample[1]] = int(by_material.get(sample[1], 0)) + 1

	var shapes := 0
	for c in map.find_children("*", "CollisionShape3D", true, false):
		shapes += 1
	print("[probe] %s %s: %d shapes, %d sample surfaces, %d solid, %d FELL THROUGH (%.1f%%)"
		% [id, "trimesh (the old collider)" if trimesh else "brush hulls",
			shapes, points.size(), caught, through,
			100.0 * float(through) / maxf(1.0, float(points.size()))])
	# Which surfaces they were. A fall-through on `water` or on a `func_illusionary`
	# pane is the map being read correctly -- a player is meant to go through both --
	# and a fall-through on anything else is a hole. Naming them is the difference
	# between "1.3% is fine" and knowing that it is.
	var names := by_material.keys()
	names.sort_custom(func(a, b): return int(by_material[a]) > int(by_material[b]))
	for n: String in names.slice(0, 8):
		print("[probe]   %5d  %s" % [int(by_material[n]), n])
	get_tree().quit(0)


## Every upward-facing triangle's centre in the drawn mesh, with the material it is on,
## thinned to a limit.
##
## Upward-facing because a player stands on those, and they are exactly the surfaces
## whose solidity is a thing a player finds out about at speed.
func _sample_points(map: G2GBspMap) -> Array:
	var mi := map.get_node_or_null("World") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return []
	var out: Array = []
	var surfaces: Array = map.manifest.get("surfaces", [])
	for s in range(mi.mesh.get_surface_count()):
		var material := "?"
		if s < surfaces.size():
			material = "%s [%s]" % [(surfaces[s] as Dictionary).get("material", "?"),
				(surfaces[s] as Dictionary).get("role", "?")]
		var arrays := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, indices.size() - 2, 3):
			var a := verts[indices[i]]
			var b := verts[indices[i + 1]]
			var c := verts[indices[i + 2]]
			# The stored normal, not one derived from the winding. Godot's front face is
			# clockwise and the importer reverses Source's winding to match, so a cross
			# product over the indices as they sit here points INTO the solid -- which
			# would quietly make this a probe of every ceiling in the map.
			var normal := normals[indices[i]] + normals[indices[i + 1]] + normals[indices[i + 2]]
			if normal.length_squared() < 1e-9 or normal.normalized().y < 0.7:
				continue
			out.append([(a + b + c) / 3.0, material])
	out.shuffle()
	return out.slice(0, SAMPLE_LIMIT)
