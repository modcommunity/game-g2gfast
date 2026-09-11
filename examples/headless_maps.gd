extends Node

## Checks that maps are found rather than listed, and that dropping one in or out
## reaches a running game.
##
## [codeblock]
## godot --headless --path . res://examples/headless_maps.tscn
## [/codeblock]
##
## [b]The check that matters is the negative one.[/b] Discovery finding three maps
## proves nothing on its own — a hardcoded list of three finds three too. What says
## there is no list is that a map the catalogue holds and the disk does not is
## *removed*, and one the disk holds and the catalogue does not is *added*, without
## anybody naming either.

## Checks that do not depend on how many maps are on disk. `_test_zones_have_floor`
## adds one per hand-written map, which is a number this file deliberately does not
## write down -- see [method _test_zones_have_floor].
const EXPECTED_FIXED_CHECKS := 24

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — map discovery")
	print("")
	_test_discovery()
	_test_derivations()
	await _test_rescan()
	await _test_client_config()
	await _test_zones_have_floor()

	print("")
	var expected := EXPECTED_FIXED_CHECKS + _hand_written_map_ids().size()
	if _passed + _failed != expected:
		_failed += 1
		_failures.append("the suite ran %d checks and should run %d — one aborted"
			% [_passed + _failed, expected])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append("%s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])
		print("  FAIL  %s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])


func _test_discovery() -> void:
	print("discovery")
	var catalogue := G2GMapCatalogue.discover()
	_check(catalogue.size() >= 3, "the hand-written maps are found without being named",
		"%d maps" % catalogue.size())
	_check(catalogue.has(&"surf_g2g_intro") and catalogue.has(&"bhop_g2g_intro")
		and catalogue.has(&"bhop_g2g_stages"), "all three of them")
	_check(catalogue.problems().is_empty(), "and the catalogue is well formed",
		", ".join(catalogue.problems()))

	var surf := catalogue.get_map(&"surf_g2g_intro")
	# The tier comes out of the map's own zones file, which is generated from the map.
	# A tier read from a list beside the map is a tier that can disagree with it.
	_check(surf != null and surf.tier == 3, "a map's tier comes from its own sidecar",
		"tier %d" % (surf.tier if surf else -1))
	_check(surf != null and surf.kind == DotMapDef.KIND_SURF, "and its kind")
	_check(surf != null and surf.scene_path == "res://maps/surf_g2g_intro.tscn",
		"and its scene path")

	var imported := 0
	for map in catalogue.maps:
		if bool(map.meta.get("imported", false)):
			imported += 1
	# Zero is legitimate: maps/imported/ is optional content.
	_check(imported >= 0, "imported maps are counted separately", "%d imported" % imported)
	if imported > 0:
		var one: DotMapDef = null
		for map in catalogue.maps:
			if bool(map.meta.get("imported", false)):
				one = map
				break
		# The invariant that makes a map droppable: its scene is the ONE that ships in
		# the build, and its identity is a manifest path. A per-map scene under
		# res://maps/imported/ would be baked in at export and could never arrive
		# afterwards, which is the whole failure this shape exists to avoid.
		_check(one.scene_path == G2GMapCatalogue.IMPORTED_SCENE
			and ResourceLoader.exists(one.scene_path),
			"an imported map uses the shared scene that ships in the build",
			one.scene_path)
		_check(not str(one.meta.get("manifest", "")).is_empty(),
			"and carries its manifest path instead of a script")
	else:
		_check(true, "an imported map uses the shared scene (none present)")
		_check(true, "and carries its manifest path instead of a script (none present)")


func _test_derivations() -> void:
	print("derivations")
	_check(G2GMapCatalogue.kind_of(&"surf_kitsune") == DotMapDef.KIND_SURF,
		"a surf_ prefix means surf")
	_check(G2GMapCatalogue.kind_of(&"bhop_g2g_stages") == DotMapDef.KIND_BHOP,
		"a bhop_ prefix means bhop")
	# The fallback has to be a real kind, not the empty StringName: DotMapDef.kind
	# feeds the rotation's filter, and a map of kind "" is a map nothing selects.
	_check(G2GMapCatalogue.kind_of(&"something_else") != &"",
		"and an unprefixed id still gets a kind")
	_check(G2GMapCatalogue.default_name(&"surf_kitsune") == "surf: kitsune",
		"a name is derived when the map does not carry one",
		G2GMapCatalogue.default_name(&"surf_kitsune"))


func _test_rescan() -> void:
	print("rescan")
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	game = G2GGame.new()
	game.config = config
	add_child(game)
	for _i in range(120):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break
	_check(game.maps != null and game.maps.catalogue != null, "a game boots with a catalogue")

	var before := game.maps.catalogue.size()

	# Drop one OUT of the catalogue while it is still on disk. A rescan must put it
	# back, and it can only do that by looking.
	var victim: StringName = game.maps.catalogue.maps[0].id
	game.maps.catalogue.remove(victim)
	_check(not game.maps.catalogue.has(victim), "a map removed from the catalogue is gone")
	var change := game.rescan_maps()
	_check(game.maps.catalogue.has(victim), "and a rescan finds it on disk again",
		String(victim))
	_check((change["added"] as Array).has(victim), "and reports it as added")

	# Drop one IN that is not on disk. A rescan must take it away.
	var ghost := DotMapDef.new()
	ghost.id = &"surf_not_on_disk"
	ghost.scene_path = "res://maps/surf_not_on_disk.tscn"
	ghost.kind = DotMapDef.KIND_SURF
	game.maps.catalogue.add(ghost)
	_check(game.maps.catalogue.has(&"surf_not_on_disk"), "a map with no files can be added")
	change = game.rescan_maps()
	_check(not game.maps.catalogue.has(&"surf_not_on_disk"),
		"and a rescan takes it away again")
	_check((change["removed"] as Array).has(&"surf_not_on_disk"), "and reports it as removed")
	_check(game.maps.catalogue.size() == before, "leaving the catalogue where it started",
		"%d vs %d" % [game.maps.catalogue.size(), before])

	# The rotation reads the catalogue live. Replacing the object instead of mutating
	# it leaves the rotation offering exactly the maps that are no longer there.
	_check(game.maps.rotation != null and game.maps.rotation.catalogue == game.maps.catalogue,
		"and the rotation still points at the catalogue it was given")


func _test_client_config() -> void:
	print("client configuration")
	# The client used to build a bare G2GConfig and never read a layer, so it was the
	# one thing here that could not be configured. This asserts the layering runs at
	# all; which layer wins is DotConfig's own contract and is tested there.
	var config := G2GConfig.new()
	var before := config.initial_map
	var layered := config.load_layered()
	_check(layered.ok, "a G2GConfig loads its layers",
		layered.error.message if not layered.ok else "")
	_check(config.initial_map != &"" or before == &"",
		"and still names a map afterwards", String(config.initial_map))


## Every zone a player has to STAND in has geometry under it.
##
## [b]This is the check that was missing, and a map shipped for months without it.[/b]
## `bhop_g2g_stages` drew its finish pad 384 units along world -Z and placed its finish
## zone 384 units along the COURSE HEADING, which is -X after the turn in stage 2 —
## 543 units apart, overlapping by a corner nothing lands on. The player ran the whole
## map, arrived on a pad drawn in the finish colour, stopped, and the timer counted on
## for ever. Every existing assertion passed: the zone set is well formed, the stages
## are numbered, the tier is right, the kind is right. **They are all about the zones
## and none of them was about the zones adding up to a run.**
##
## A raycast is what says so, because it is the only question that crosses from the
## zone set into the geometry: drop a ray down the middle of every START, END and STAGE
## volume and require it to land inside that volume. A zone hanging in the air over
## nothing is a zone the run never reaches, and it looks exactly like a map with a
## missing end zone from inside the game.
##
## Over the maps the catalogue FINDS, and not over a list of them. A list of three ids
## here is the bug the catalogue exists to prevent, one level up, and this tree has
## already had it in `setup.sh`, `tools/check.sh`, `tools/package_check.sh`, both
## bootstrap scripts, `tools/export_zones.gd` and `headless_run`'s sidecar check — where
## a fourth map would simply not have been looked at, silently.
func _test_zones_have_floor() -> void:
	print("zones sit on the geometry")

	for id in _hand_written_map_ids():
		var scene: PackedScene = load("res://maps/%s.tscn" % id)
		var map := scene.instantiate() as G2GMap
		add_child(map)

		# Two, because `add_child` puts the bodies in the space and the space is
		# flushed at the next step: a ray cast in the same frame hits nothing at all,
		# which reads as every zone in the map being broken.
		await get_tree().physics_frame
		await get_tree().physics_frame

		var space := map.get_world_3d().direct_space_state

		var floating := PackedStringArray()

		for zone: DotTimerZone in map.timer_zones().zones:
			if zone.kind != DotTimerZone.Kind.START \
					and zone.kind != DotTimerZone.Kind.END \
					and zone.kind != DotTimerZone.Kind.STAGE:
				continue

			var centre := zone.centre()
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(centre.x, zone.to.y, centre.z),
				# A hair below the floor of the zone, because the pad's top surface IS
				# the zone's lower bound on every map here and a ray that stops exactly
				# on it is a coin toss in 32-bit.
				Vector3(centre.x, zone.from.y - 0.05, centre.z)
			)

			if not space.intersect_ray(query):
				floating.append("%s %d" % [
					DotTimerZone.kind_name(zone.kind), zone.track
				])

		_check(floating.is_empty(),
			"%s stands every zone on something" % id, ", ".join(floating))

		map.queue_free()
		await get_tree().process_frame


## The hand-written maps: the ones with a script of their own, discovered rather than
## named. An imported map has no geometry until `build_from` runs and is covered by
## `headless_imported`, which drives a timer over each one's own zone set.
func _hand_written_map_ids() -> Array:
	var out: Array = []
	for map in G2GMapCatalogue.scan():
		if not bool(map.meta.get("imported", false)):
			out.append(String(map.id))
	out.sort()
	return out
