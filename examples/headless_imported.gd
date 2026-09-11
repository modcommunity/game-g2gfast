extends Node

## Checks a map imported from a Source .bsp: it loads, it is the right size, it is
## lit, and — the only question that matters — a player put on it stays on it.
##
## [codeblock]
## godot --headless --path . res://examples/headless_imported.tscn
## [/codeblock]
##
## [b]Why collision is the check and geometry is not.[/b] Every number about an
## imported map can be right while the map is unplayable: the vertex count, the
## bounds, the material list and the manifest all pass if the triangles are wound
## inside out or the collision body was never built, and a player then falls through
## a map that renders perfectly. This file's own repeated lesson — a value produced
## correctly and consumed by nothing — reaches imported geometry through collision.
##
## Skips rather than fails when nothing has been imported: `maps/imported/` is
## optional content and a clone that has never run the importer is not broken.

## Checks every map gets. Tracks and stages add one each on top — see [member _expected].
const CHECKS_PER_MAP := 25

## A script error inside a test aborts THAT TEST and not the run, so a suite that has
## quietly lost two checks still prints "0 failed" — which is what happened while this
## file was being written, to the zone section. The count is asserted, not trusted.
var _expected := 0
var _map_id: StringName = &""

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — imported map")
	print("")

	# Every map under maps/imported/, not one this file names. A suite with its own
	# copy of the list is the bug the discovery in G2GGame exists to avoid.
	var ids := _imported_ids()
	if ids.is_empty():
		print("nothing in maps/imported/ — nothing to check")
		print("  tools/bsp_import.py <a .bsp> maps/imported --id <name>")
		get_tree().quit(0)
		return

	for id in ids:
		_map_id = id
		_expected += CHECKS_PER_MAP
		print("=== %s" % id)
		await _test_loads("res://maps/imported/%s/%s.json" % [id, id])
		await _test_geometry()
		await _test_lighting()
		_test_zones()
		_test_runnable()
		await _test_stands_on_it()
		await _test_stands_where_it_sends_you()
		if game != null:
			game.queue_free()
			game = null
			await get_tree().process_frame

	print("")
	if _passed + _failed != _expected:
		_failed += 1
		_failures.append("the suite ran %d checks and should run %d — one aborted"
			% [_passed + _failed, _expected])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 else 0)


func _imported_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	var dir := DirAccess.open("res://maps/imported")
	if dir == null:
		return out
	for id in dir.get_directories():
		if FileAccess.file_exists("res://maps/imported/%s/%s.json" % [id, id]):
			out.append(StringName(id))
	out.sort()
	return out


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append("%s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])
		print("  FAIL  %s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])


func _test_loads(manifest_path: String) -> void:
	print("loading")
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = _map_id

	game = G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	_check(game.maps != null and game.maps.current != null and game.maps.current.id == _map_id,
		"the imported map is in the catalogue and loads")
	# Discovery, not a list. If this fails the map was found by something naming it.
	_check(FileAccess.file_exists(manifest_path), "its manifest is beside it")


func _test_geometry() -> void:
	print("geometry")
	var node := game.current_map_node()
	_check(node is G2GBspMap, "the map node is a G2GBspMap")
	var mi := node.get_node_or_null("World") as MeshInstance3D
	_check(mi != null and mi.mesh != null, "it built a mesh")
	if mi == null or mi.mesh == null:
		return
	var mesh := mi.mesh
	_check(mesh.get_surface_count() > 1, "with a surface per material",
		"%d surfaces" % mesh.get_surface_count())

	var verts := 0
	var has_uv2 := true
	for i in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(i)
		verts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if arrays[Mesh.ARRAY_TEX_UV2] == null:
			has_uv2 = false
	_check(verts > 1000, "and real geometry", "%d verts" % verts)
	# UV2 is the whole reason this is not a glTF import. If it is gone the map is lit
	# by whatever texel the atlas happens to have at (0,0).
	_check(has_uv2, "and a second UV set on every surface, for the baked lighting")

	var aabb := mi.get_aabb()
	var units := aabb.size / G2GUnits.METRES_PER_UNIT
	# Source's own limit is +/-16384 units, so a map is at most 32768 across. Ten
	# times that means the unit ratio was applied twice or not at all -- the one
	# mistake that makes an imported map silently unplayable rather than wrong.
	_check(units.x > 1000.0 and units.x < 40000.0 and units.y < 40000.0,
		"and is the size a Source map can be", "%.0f x %.0f x %.0f units" % [units.x, units.y, units.z])


func _test_lighting() -> void:
	print("lighting")
	var node := game.current_map_node() as G2GBspMap
	var lm: Dictionary = node.manifest.get("lightmap", {})
	var path: String = "res://maps/imported/%s/%s" % [_map_id, lm.get("file", "")]
	_check(ResourceLoader.exists(path), "the baked lightmap atlas is an imported resource", path)

	var mi := node.get_node_or_null("World") as MeshInstance3D
	var mat := mi.get_surface_override_material(0) as ShaderMaterial if mi != null else null
	_check(mat != null, "surfaces carry a ShaderMaterial")
	if mat == null:
		return
	_check(mat.get_shader_parameter("lightmap_tex") is Texture2D,
		"and the atlas is bound to every one of them")


func _test_zones() -> void:
	print("zones")
	var zones := game.timers.zones
	_check(zones != null, "the map produced a zone set")
	if zones == null:
		return
	_check(zones.problems().is_empty(), "which is well formed", ", ".join(zones.problems()))
	var respawns := zones.of_kind(DotTimerZone.Kind.RESPAWN).size()
	# A surf map's trigger_teleport volumes are its pit. Losing them means a player
	# who falls off falls for ever, which is the bug dot-timer's effect_requested was.
	_check(respawns > 0, "with the pit volumes carried across as RESPAWN zones",
		"%d respawn zones" % respawns)

	# Source sweeps its trigger tests; dot-timer samples a point per tick. A pit drawn
	# as a 16-unit plane -- which is how every one of them is drawn, because in Source
	# that is enough -- is stepped clean over by a player falling at genre speed, and
	# they then fall for ever. 48 of surf_kitsune's 53 were that thin on import.
	var thin := zones.thin_zones(G2GUnits.to_metres(3500.0), game.tick_rate)
	_check(thin.is_empty(), "and no zone a 3500 u/s player passes through between ticks",
		"%d thin" % thin.size())

	# The two zones without which a map is scenery. Every one of these maps had them
	# in its entity lump or in maps/zones/ before it was offered as a level; a map
	# that reaches here without them is one the importer stopped reading.
	var tracks := zones.playable_tracks()
	_check(tracks.has(DotTimerTrack.MAIN),
		"the main track has both a start line and a finish",
		"runnable tracks: %s" % str(tracks))

	# A track a player cannot be put on is a track nobody plays. `spawn_for` falls
	# back to `fallback_spawn_units` for a missing one, which is the main track's
	# spawn -- so a bonus with no spawn of its own silently starts at the map's start,
	# and looks like a bonus that does not work rather than like a missing zone.
	var without := PackedStringArray()
	for track in tracks:
		if zones.first_of_kind(DotTimerZone.Kind.SPAWN, track) == null:
			without.append(DotTimerTrack.name_of(track))
	_check(without.is_empty(), "and every runnable track has somewhere to spawn",
		", ".join(without))


func _test_runnable() -> void:
	print("runnable")
	var zones := game.timers.zones
	if zones == null:
		_check(false, "a run can be started, split and finished")
		_check(false, "and its stages come out in order")
		return

	# [b]Drive the timer over the map's own zones and see a time come out.[/b] Every
	# other check here is about a zone existing; this is the only one about the zones
	# adding up to a run. A start with no reachable finish, a stage numbered past the
	# end, a finish inside the start -- all of them pass `problems()` and none of them
	# produces a time.
	var timer := DotTimer.new()
	timer.bind(zones, game.tick_rate)
	var finished: Array[DotTimerRun] = []
	timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))

	var start := zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	var finish := zones.first_of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	if start == null or finish == null:
		_check(false, "a run can be started, split and finished", "no start or no end")
		_check(false, "and its stages come out in order")
		return

	# [b]A tick outside every zone, between the start and everything after it.[/b] The
	# run begins on the tick the player LEAVES the start line, and that happens after
	# the zone handling for the same tick -- so a route that steps straight from the
	# start into the first stage arrives while the run is still IDLE and the split is
	# dropped. It is an artifact of stepping a timer by hand rather than walking a
	# map, and it cost every staged map here exactly one split until the gap was put
	# back in.
	var bounds: Dictionary = (game.current_map_node() as G2GBspMap).manifest.get("bounds", {})
	var away := G2GUnits.vector_to_metres(Vector3(
		float((bounds.get("max", [0, 0, 0]) as Array)[0]),
		float((bounds.get("max", [0, 0, 0]) as Array)[1]),
		float((bounds.get("max", [0, 0, 0]) as Array)[2]))) + Vector3(0.0, 128.0, 0.0)

	# From stage 2, because stage 1 IS the start line on every map that numbers its
	# own stages -- and stepping back into the start zone mid-route makes the timer do
	# what it should: treat leaving it again as a new attempt, wiping the splits.
	var route: Array[Vector3] = [start.centre(), start.centre(), away]
	for n in range(2, zones.stage_count(DotTimerTrack.MAIN) + 1):
		var stage := zones.stage_zone(DotTimerTrack.MAIN, n)
		if stage != null:
			route.append(stage.centre())
	route.append(finish.centre())

	var sample := DotTimerSample.new()
	for point in route:
		sample.previous_position = sample.position
		sample.position = point
		sample.grounded = true
		timer.tick(sample)

	_check(finished.size() == 1, "a run can be started, split and finished",
		"%d finishes" % finished.size())
	if finished.is_empty():
		_check(false, "and its stages come out in order")
		return

	# Stage 1 is the start line, and a run begins by LEAVING it -- so its split is the
	# one that legitimately never arrives. Every stage after it must.
	var wanted := maxi(0, zones.stage_count(DotTimerTrack.MAIN) - 1)

	var got := 0
	for n in range(2, zones.stage_count(DotTimerTrack.MAIN) + 1):
		if finished[0].splits.has(n):
			got += 1
	_check(got == wanted, "and its stages come out in order",
		"%d of %d splits" % [got, wanted])


func _test_stands_on_it() -> void:
	print("collision")
	var node := game.current_map_node()
	# Anywhere under the map, not under the MeshInstance3D. The solid used to BE the
	# mesh -- `create_trimesh_collision()` parents a `World_col` to it -- and it is not
	# any more: it is built from the .bsp's brushes, which is a different set of
	# geometry from the drawn faces and belongs to the map rather than to the drawing of
	# it. The old shape is still what a pre-collision manifest falls back to, so this
	# has to find both.
	var body: Node = null
	for c in node.find_children("*", "StaticBody3D", true, false):
		body = c
		break
	_check(body is StaticBody3D, "the world has a static body")
	var shape_count := 0
	if body != null:
		for c in body.get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape != null:
				shape_count += 1
	_check(shape_count > 0, "with a collision shape on it", "%d shapes" % shape_count)

	var bot := game.add_player(&"bot", "Bot", true)
	_check(bot != null, "a player joins")
	if bot == null:
		return
	bot.sampler = null

	var start := node.spawn_for(0)
	await get_tree().physics_frame
	_check(bot.global_position.distance_to(start) < 2.0, "at the map's own spawn",
		"%.1f m away" % bot.global_position.distance_to(start))

	# Let it fall. On a map whose collision never got built this is the only check in
	# the file that fails, and it fails by hundreds of metres rather than marginally.
	var floor_y := start.y
	for _i in range(180):
		await get_tree().physics_frame
	var drop := floor_y - bot.global_position.y
	_check(drop < 8.0, "and is still standing on the map three seconds later",
		"fell %.1f m" % drop)

	var bounds: Dictionary = (node as G2GBspMap).manifest.get("bounds", {})
	var min_y: float = float((bounds.get("min", [0, -16384, 0]) as Array)[1]) * G2GUnits.METRES_PER_UNIT
	_check(bot.global_position.y > min_y, "and has not left the world",
		"y=%.1f, world floor %.1f" % [bot.global_position.y, min_y])


## Every place the map can put a player: each track's spawn, and each `!s<n>`.
##
## [b]A destination is the one field nothing else checks.[/b] `DotTimerManager`
## resolves "go to stage 3" to a zone's [member DotTimerZone.destination] and hands it
## to the host, which teleports; a destination that is in the sky, inside a wall, or
## left at the origin succeeds at every step and drops the player out of the world.
## Standing on it for a second is the whole test, and it is the same test as the one
## above with somewhere else to stand.
func _test_stands_where_it_sends_you() -> void:
	print("destinations")
	var node := game.current_map_node()
	var zones := game.timers.zones
	var spots: Array = []
	if zones != null:
		for track in zones.playable_tracks():
			var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
			if spawn != null:
				spots.append([DotTimerTrack.short_name_of(track) + " spawn", spawn.destination])
			for n in range(1, zones.stage_count(track) + 1):
				var stage := zones.stage_zone(track, n)
				if stage != null:
					spots.append(["stage %d" % n, stage.destination])
	_expected += spots.size()

	var bot: G2GPlayer = game.players.get(&"bot")
	if bot == null:
		bot = game.add_player(&"bot", "Bot", true)
		bot.sampler = null
	for spot: Array in spots:
		var at: Vector3 = spot[1]
		bot.teleport(at, 0.0)
		for _i in range(90):
			await get_tree().physics_frame
		var drop := at.y - bot.global_position.y
		_check(drop < 8.0, "%s is somewhere a player can stand" % spot[0],
			"fell %.1f m from %s" % [drop, str(at / G2GUnits.METRES_PER_UNIT)])
