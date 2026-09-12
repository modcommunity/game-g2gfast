extends Node

## The player stack, run against a real timer server rather than against a stub.
##
## [codeblock]
## godot --headless --path . res://examples/headless_stack.tscn
## [/codeblock]
##
## [b]This game gained a three-hundred-line player layer with no suite that named it.[/b]
## game-arena got one; the other four did not, so the roster, the sides, the classes, the
## collision layout and the spawn director were exercised only as far as `setup()` running
## inside somebody else's test. Every failure below is one that can only happen at a seam.
##
## The two that matter most here are this game's own:
##
## - **The director actually chooses a start**, and chooses the one belonging to the track
##   the player is on. It was built, fed every track's start, and asked nothing at all for
##   the life of the server; the fallback below it read the map live, so the path that had
##   never run was the correct one and the path that replaced it was not.
## - **The sites follow a map change.** A respawn can run before this node's `map_ready`
##   handler does, and the director then answers — confidently, with a real transform —
##   from the map nobody is standing in.

const CHECKS := 29

var _passed := 0
var _failed := 0
var _section_count := 0
var _sections := 0

var _game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("g2gfast player stack")
	print("")

	if not await _build():
		get_tree().quit(1)
		return

	_test_physics_layout()
	_test_roster_and_sides()
	_test_classes()
	await _test_spawn_director()
	_test_protection_is_shut_without_deathmatch()

	print("")
	print("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != _sections:
		print("ERROR: %d of %d sections ran." % [_section_count, _sections])
		get_tree().quit(1)
		return

	# The total the section counter cannot be: a runtime error inside a section aborts
	# that function and the counter is already satisfied, because the section announced
	# itself before it ran. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _build() -> bool:
	_sections = 5

	var config := G2GConfig.new()
	config.initial_map = &"bhop_g2g_intro"

	_game = G2GGame.new()
	_game.name = "Game"
	_game.config = config
	add_child(_game)

	for _i in range(120):
		await get_tree().process_frame

		if _game.maps != null and _game.maps.current != null:
			break

	if _game.player_stack == null:
		print("  FAIL  the game set up without a player stack")
		return false

	return true


func _stack() -> G2GPlayerStack:
	return _game.player_stack


# --- 1 ----------------------------------------------------------------------

func _test_physics_layout() -> void:
	_section("the collision layout is applied, not just named")

	var physics := _stack().physics
	_check(physics != null, "the stack built a physics world")

	if physics == null:
		return

	_check(physics.layout != null, "with a layout on it")
	_check(
		physics.layout.has_layer(&"world") and physics.layout.has_layer(&"player"),
		"that knows the two layers this game actually uses"
	)

	# The half that was missing: names in ProjectSettings and nothing wearing them.
	var mask := _stack().player_collision_mask()
	_check(mask != 1, "the player mask is the layout's, not DotFpsTunables' default of 1")
	_check(
		mask & physics.layout.layer_mask(&"world") != 0,
		"and it still includes the world, which is what a player stands on"
	)
	_check(
		mask & physics.layout.layer_mask(&"prop") != 0,
		"and props, which is what stops a player walking through a placed block"
	)

	var level := _game.current_map_node()
	_check(level != null, "the map is loaded")

	if level != null:
		var on_world := 0

		for child in level.get_children():
			var body := child as CollisionObject3D

			if body != null and body.collision_layer == physics.layout.layer_mask(&"world"):
				on_world += 1

		_check(
			on_world > 0,
			"and its geometry is ON the world layer — before this every box was on "
			+ "Godot's default layer 1 while the inspector named the layers something else"
		)


# --- 2 ----------------------------------------------------------------------

func _test_roster_and_sides() -> void:
	_section("a player reaches the roster and the sides")

	var player := _game.add_player(&"ada", "Ada")
	_check(player != null, "a player joins the game")

	var roster := _stack().roster
	_check(roster.has_player("ada"), "and lands in the session roster")

	var teams := _stack().teams
	_check(teams.has_player("ada"), "and on a side")

	# The number dot-spectate is given, which was a hardcoded 1 in four games.
	var index := _stack().team_index_of("ada")
	_check(
		index > 0,
		"team_index_of answers a playing side rather than a constant"
	)
	_check(
		_stack().team_index_of("nobody") == 0,
		"and answers 0 for somebody who is not in the roster, because dot-spectate "
		+ "reads 0 as 'no team' and two of those are never team-mates"
	)


# --- 3 ----------------------------------------------------------------------

func _test_classes() -> void:
	_section("the class document is readable and applied")

	var classes := _stack().classes
	_check(classes != null, "the stack built a class manager")
	_check(classes.def_of("ada") != null, "and a joining player has a class")

	var def := classes.def_of("ada")

	if def == null:
		return

	# The bridge that had no caller anywhere in this family.
	var health := StubHealth.new()
	_check(
		DotPlayerClassApply.to_health(def, health) > 0,
		"a class's numbers can be written onto a health component"
	)
	_check(
		is_equal_approx(health.max_health, def.max_health),
		"and the maximum is the class's"
	)
	health.free()


# --- 4 ----------------------------------------------------------------------

func _test_spawn_director() -> void:
	_section("the director chooses the start, and follows the map")

	var spawns := _stack().spawns
	_check(spawns.sites().size() > 0, "the director has the map's starts in it")

	var main := _stack().choose_start(&"ada", DotTimerTrack.MAIN)
	_check(main.ok, "and answers for the main track", )

	if not main.ok:
		return

	var chosen := main.value as DotSpawnChoice
	_check(
		int(chosen.site.meta.get("track", -1)) == DotTimerTrack.MAIN,
		"with the site belonging to the track that was asked for — a course's tracks "
		+ "each start somewhere else, so any site is the wrong site"
	)

	var map := _game.current_map_node()
	_check(
		chosen.transform.origin.distance_to(map.spawn_for(DotTimerTrack.MAIN)) < 0.01,
		"and the same place the map itself would have said"
	)

	# The yaw, which is the pair of unit conversions nothing had ever exercised: a site
	# holds radians and DotFpsState.yaw is degrees, and the site was being built from the
	# map's degrees.
	_check(
		absf(
			rad_to_deg(chosen.transform.basis.get_euler().y)
			- map.spawn_yaw_for(DotTimerTrack.MAIN)
		) < 0.5,
		"facing the way the map says, which is a radians-to-degrees conversion at both "
		+ "ends and was wrong at both"
	)

	# And the part a map change breaks.
	var before := spawns.sites().size()
	var changed: DotResult = await _game.change_map(&"surf_g2g_intro")
	_check(changed.ok, "the map changes")

	var after := _stack().choose_start(&"ada", DotTimerTrack.MAIN)
	_check(after.ok, "and the director still answers")

	if after.ok:
		var new_map := _game.current_map_node()
		_check(
			(after.value as DotSpawnChoice).transform.origin.distance_to(
				new_map.spawn_for(DotTimerTrack.MAIN)
			) < 0.01,
			"from the NEW map — a director holding the previous map's sites answers "
			+ "with a real site, a real transform and a successful result, for a map "
			+ "nobody is standing in"
		)

	_check(before > 0, "and had sites before the change as well")


# --- 5 ----------------------------------------------------------------------

func _test_protection_is_shut_without_deathmatch() -> void:
	_section("spawn protection exists only where there is something to be shot by")

	var spawns := _stack().spawns
	_stack().refresh_spawn_rules()

	_check(
		is_equal_approx(spawns.rules.protection_sec, 0.0),
		"a pure timer server opens no protection window, because nothing on it can "
		+ "hurt anybody"
	)
	_check(
		not _stack().blocks_damage("ada", "bob", _game.current_tick()),
		"so nothing is ever blocked"
	)
	_check(
		not spawns.rules.protection_breaks_on_attack,
		"and breaking on attack is off, because only one of the two records of a "
		+ "protection window can be revoked and a half-revoked one is worse than either"
	)

	_game.queue_free()


# --- Harness ---------------------------------------------------------------

## Stands in for a `DotHealth` without this project installing dot-combat.
class StubHealth extends Object:
	var max_health: float = 1.0
	var max_armour: float = 0.0


func _section(title: String) -> void:
	_section_count += 1
	print("")
	print("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
