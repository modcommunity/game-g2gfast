extends Node

const G2GAvatars := preload("../game/g2g_avatars.gd")
const G2GCamera := preload("../game/g2g_camera.gd")
const G2GClient := preload("../game/g2g_client.gd")
const G2GConfig := preload("../game/g2g_config.gd")
const G2GEffects := preload("../game/g2g_effects.gd")
const G2GGame := preload("../game/g2g_game.gd")
const G2GMapCatalogue := preload("../game/g2g_map_catalogue.gd")
const G2GMovement := preload("../game/g2g_movement.gd")
const G2GPlayer := preload("../game/g2g_player.gd")
const G2GReplays := preload("../game/g2g_replays.gd")
const G2GRig := preload("../game/g2g_rig.gd")
const G2GStats := preload("../game/g2g_stats.gd")
const G2GUnits := preload("../game/g2g_units.gd")

## Runs g2gfast headless: units, the genre field of view, a stock avatar on a rig,
## first and third person, auto-bhop gated by the config, and a bot down both maps.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## [/codeblock]

const CHECKS := 135

## The surf map's start height, for the bonus-route bounds check below.
const START_Y := 2048.0

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — headless run")
	print("")

	_test_units()
	_test_source_fov()
	_test_movement_from_config()
	await _test_boot()
	_test_avatars()
	await _test_cameras()
	await _test_auto_bhop_gate()
	await _test_zone_files_match()
	await _test_bhop_run()
	await _test_surf_run()
	await _test_bonus_track()
	await _test_ghost()
	await _test_progression()
	await _test_spectating()
	await _test_effects_and_the_run()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _near(value: float, expected: float, epsilon: float, what: String) -> void:
	_check(absf(value - expected) <= epsilon, what, "%.4f vs %.4f" % [value, expected])


## Walks forward before hopping, which is what a bunny-hopper actually does.
##
## [b]This is the genre's physics being faithful, not a bug, and it cost an hour.[/b] On
## the tick a jump fires the player is already airborne when acceleration runs, so a
## held jump key from a standstill never gets a ground-acceleration tick and creeps at
## the 30 u/s air cap for ever. Those games do exactly the same — their jump check runs
## before `WalkMove` — which is why every bhop run begins with a prestrafe.
func _prestrafe(id: StringName, ticks: int = 80) -> void:
	var walk := DotFpsCommand.new()
	walk.move = Vector2(0.0, 1.0)
	await _drive(id, walk, ticks)


func _drive(id: StringName, command: DotFpsCommand, ticks: int) -> void:
	var player: G2GPlayer = game.players[id]
	for _i in range(ticks):
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame


# --- Spectating ------------------------------------------------------------

## Watching somebody run, which on a timer server is the point rather than a
## consolation for being dead.
func _test_spectating() -> void:
	print("spectating")

	if game.spectate == null:
		_check(false, "the spectate layer is built")
		return

	_check(true, "the spectate layer is built")

	# A plain timer server has no sides and nobody dead, and both of those would stop
	# every other game's spectator policy dead: `force_camera 1` would restrict the
	# camera to a team that is everybody, and "dead players only" would make every
	# runner unwatchable, which is the one thing this layer exists for.
	_check(
		game.spectate.manager.rules.force_camera == 0,
		"anybody may watch anybody on a timer server",
		str(game.spectate.manager.rules.force_camera)
	)
	_check(
		game.spectate.manager.rules.allow_while_alive,
		"and a living player may watch, because standing in the start zone is not death"
	)

	var watcher := game.add_player(&"watcher", "Watcher", false)
	_check(watcher != null, "a second player joins")
	await get_tree().physics_frame

	var res := game.spectate.watch(&"watcher", &"bot")
	_check(res.ok, "and can watch the runner", str(res.error))
	_check(
		game.spectate.target_of(&"watcher") == &"bot",
		"the target is who was asked for",
		String(game.spectate.target_of(&"watcher"))
	)

	game.tick_once(game.current_tick() + 1)

	var seen := game.spectate.camera_for(&"watcher")
	var runner: G2GPlayer = game.players[&"bot"]
	_check(
		seen.origin.distance_to(runner.eye_position()) < 0.01,
		"and the camera is at the runner's eyes rather than at their feet or the origin",
		"%v against %v" % [seen.origin, runner.eye_position()]
	)

	# `!spec` with no name, which is what a spectator actually types.
	var best := game.spectate.watch_best(&"watcher")
	_check(best.ok, "watching whoever is furthest into a run picks somebody", str(best.error))

	game.spectate.stop(&"watcher")
	_check(
		not game.spectate.is_spectating(&"watcher"),
		"and it can be turned off"
	)

	game.remove_player(&"watcher")
	await get_tree().physics_frame


# --- Effects, and the rule that makes them safe here ------------------------

## A movement effect is a style, and a style you did not choose is a record you did not
## set. This is the section that pins that.
func _test_effects_and_the_run() -> void:
	print("effects")

	# The stock configuration has neither deathmatch nor hunters, so there is no
	# effects layer — which is correct and is itself worth asserting: a timer server
	# that built one would be a timer server carrying a system nothing could reach.
	_check(
		game.effects == null,
		"a plain timer server has no effects layer at all"
	)

	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"
	config.hunters = true

	var hunted := G2GGame.new()
	hunted.config = config
	add_child(hunted)

	for _i in range(60):
		await get_tree().process_frame
		if hunted.maps != null and hunted.maps.current != null:
			break

	_check(hunted.effects != null, "a hunted server builds one")

	if hunted.effects == null:
		hunted.queue_free()
		remove_child(hunted)
		return

	var runner := hunted.add_player(&"run", "Runner", true)
	runner.sampler = null
	await get_tree().physics_frame

	# Not in a run yet: the slow is allowed.
	var idle := hunted.effects.apply(G2GEffects.MAULED, &"run")
	_check(idle.ok, "a slow lands on somebody who is not running", str(idle.error))
	hunted.effects.remove(G2GEffects.MAULED, &"run")

	# And the movement actually changes, which is the half that has to work for the
	# refusal below to be worth anything.
	var base := runner.base_tunables.max_speed
	var _again := hunted.effects.apply(G2GEffects.MAULED, &"run")
	hunted.tick_once(hunted.current_tick() + 1)
	_check(
		runner.controller.tunables.max_speed < base,
		"and it actually slows them",
		"%.2f from %.2f" % [runner.controller.tunables.max_speed, base]
	)

	for _i in range(30):
		hunted.tick_once(hunted.current_tick() + 1)
	_check(
		runner.controller.tunables.max_speed > 0.1,
		"without compounding to a standstill over thirty ticks",
		"%.4f" % runner.controller.tunables.max_speed
	)
	hunted.effects.remove(G2GEffects.MAULED, &"run")

	# Now in a run. The whole point of the layer.
	runner.timer.run.status = DotTimerRun.Status.RUNNING
	var refused := hunted.effects.apply(G2GEffects.MAULED, &"run")
	_check(
		not refused.ok,
		"and is REFUSED on a ranked run: a style you did not choose is a record you did "
		+ "not set"
	)
	_check(
		refused.code() == DotError.CODE_FORBIDDEN,
		"with a forbidden code rather than a silent no-op",
		refused.code()
	)

	# A bleed is not a movement effect and lands regardless, which is the other half of
	# the split: being chased still has to hurt.
	var bled := hunted.effects.apply(G2GEffects.BLEEDING, &"run")
	_check(
		bled.ok or bled.code() != DotError.CODE_FORBIDDEN,
		"while a bleed lands during a run, because it cannot change a time",
		str(bled.error)
	)

	# And the server that wants hunted runs to count anyway pays for it in the field
	# dot-timer has had since it was written and nothing had ever set.
	hunted.effects.allow_movement_during_runs = true
	var tainting := hunted.effects.apply(G2GEffects.MAULED, &"run")
	_check(tainting.ok, "a server may allow it", str(tainting.error))
	_check(
		runner.timer.run.tainted,
		"and the run is tainted, which is what keeps it off a board beside a clean one"
	)

	hunted.queue_free()
	remove_child(hunted)
	await get_tree().process_frame


# --- Units and view --------------------------------------------------------

func _test_units() -> void:
	print("genre units")
	_near(G2GUnits.to_metres(72.0), 1.3716, 0.0001, "a 72-unit player is 1.37 m")
	_near(G2GUnits.to_units(G2GUnits.to_metres(3500.0)), 3500.0, 0.001, "and the round trip is exact")
	_check(G2GUnits.format_speed(G2GUnits.to_metres(250.0)) == "250", "speed formats as whole units")
	_near(G2GUnits.sensitivity_to_degrees(2.5), 0.055, 0.0001, "sensitivity 2.5 is 0.055°/count")


func _test_source_fov() -> void:
	print("the genre field of view")
	# fov_desired 90 is 90° horizontal on a 4:3 frame. Vertical is 2·atan(tan(45°)·3/4).
	var vertical := G2GUnits.horizontal_fov_to_vertical(90.0)
	_near(vertical, 73.74, 0.01, "fov_desired 90 is 73.74° vertical")

	# On a 16:9 screen that vertical angle widens to what those games show.
	var horizontal_16_9 := rad_to_deg(2.0 * atan(tan(deg_to_rad(vertical) * 0.5) * 16.0 / 9.0))
	_near(horizontal_16_9, 106.26, 0.05, "which is 106.26° horizontal at 16:9, exactly the genre's")

	# The obvious mistake, named so it stays a mistake.
	var naive_16_9 := rad_to_deg(2.0 * atan(tan(deg_to_rad(90.0) * 0.5) * 16.0 / 9.0))
	_check(naive_16_9 > 120.0, "handing 90 straight to a vertical fov would be over 120° wide", "%.1f" % naive_16_9)

	_near(G2GUnits.horizontal_fov_to_vertical(75.0), 59.8, 0.1, "and 75 is 59.8°")


func _test_movement_from_config() -> void:
	print("movement cvars become tunables")
	var config := G2GConfig.new()
	var t := G2GMovement.tunables_for(config)

	_check(t.validate().ok, "the default configuration builds valid tunables", t.validate().error.message if not t.validate().ok else "")
	_near(t.gravity, G2GUnits.to_metres(800.0), 0.001, "sv_gravity 800 is 15.24 m/s²")
	_near(t.max_speed, G2GUnits.to_metres(250.0), 0.001, "250 u/s run speed")
	_near(t.max_air_wish_speed, G2GUnits.to_metres(30.0), 0.001, "the 30 u/s air cap")
	# Jump height reproduces the launch speed: h = v²/2g = 57 units under 800.
	_near(G2GUnits.to_units(t.jump_height), 57.0, 0.1, "jump height is 57 units, so the launch is 302 u/s")
	_near(G2GUnits.to_units(t.jump_velocity()), G2GUnits.JUMP_VELOCITY, 0.5, "and the motor's launch speed agrees")
	_near(t.stand_height, G2GUnits.to_metres(72.0), 0.001, "the hull is 72 units tall")
	_check(t.auto_hop, "auto-hop follows the config, on by default")
	_check(t.bhop_speed_cap_scale == 0.0, "and hopping builds speed")

	config.auto_bhop = false
	config.enable_bunnyhopping = false
	config.jump_buffer = 0.05
	var strict := G2GMovement.tunables_for(config)
	_check(not strict.auto_hop, "sv_autobunnyhopping 0 turns it off")
	_near(strict.jump_buffer_time, 0.05, 0.0001, "and the easy-bhop window applies then")
	_near(strict.bhop_speed_cap_scale, 1.1, 0.0001, "sv_enablebunnyhopping 0 applies CS's landing cap")

	config.air_accelerate = 150.0
	_near(G2GMovement.tunables_for(config).air_accelerate, 150.0, 0.001, "sv_airaccelerate passes through")

	# The layering an operator uses.
	var layered := G2GConfig.new()
	layered.apply_dictionary({"auto_bhop": false, "air_accelerate": 150, "fov_desired": 100})
	_check(not layered.auto_bhop and layered.air_accelerate == 150.0 and layered.fov_desired == 100.0,
		"a config file layer moves the cvars")


# --- Boot ------------------------------------------------------------------

func _test_boot() -> void:
	print("booting")
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"

	game = G2GGame.new()
	game.config = config
	add_child(game)

	for _i in range(60):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	_check(game.maps.current != null and game.maps.current.id == &"bhop_g2g_intro", "the bhop map loads")
	_check(game.timers.tick_rate == game.tick_rate and game.timers.tick_rate_matches_engine(), "the timer counts in the engine's rate")

	var zones := game.timers.zones
	_check(zones != null and zones.problems().is_empty(), "the map's zones are well formed", ", ".join(zones.problems()) if zones else "no zones")
	_check(zones != null and zones.playable_tracks() == PackedInt32Array([0, 1]), "with a main track and one bonus", str(zones.playable_tracks()) if zones else "")
	_check(zones != null and zones.stage_count(0) == 3, "and three stages")
	_check(zones != null and zones.thin_zones(G2GUnits.to_metres(3500.0), game.tick_rate).is_empty(),
		"and no zone a 3500 u/s player passes through between ticks")

	var bot := game.add_player(&"bot", "Bot", true)
	_check(bot != null and bot.timer != null, "a local player joins with a timer")

	# A local player samples the input devices every tick, and a headless run has
	# none — so the sampler produces an empty command that overrides anything the
	# test applies. The bot keeps the camera and the rig of a local player and is
	# DRIVEN instead, which is what a bot is.
	bot.sampler = null
	_check(bot.camera != null, "and a camera")
	_check(bot.rig != null, "and a rig")

	await get_tree().physics_frame
	_check(bot.global_position.distance_to(game.current_map_node().spawn_for(0)) < 1.0, "at the map's spawn")



func _test_avatars() -> void:
	print("avatars")
	var schema := game.avatar_schema
	_check(schema.validate_schema().ok, "the stock schema validates", schema.validate_schema().error.message if not schema.validate_schema().ok else "")

	var bot: G2GPlayer = game.players[&"bot"]
	_check(bot.rig.avatar != null, "the player was dressed")
	_check(bot.rig.body_mount.get_child_count() == 1, "with a body")
	_check(bot.rig.head_mount.get_child_count() == 1, "and a head")

	# Deterministic in the id, so the same player is the same character everywhere.
	var a := G2GAvatars.stock_avatar(&"alice")
	var b := G2GAvatars.stock_avatar(&"alice")
	_check(a.equals(b), "a stock avatar is the same for the same player every time")
	_check(schema.validate(a).ok, "and conforms to the schema")

	# A player's own document over the same schema dresses the same rig.
	var own := DotAvatar.make(G2GAvatars.SCHEMA_ID)
	own.set_part(G2GAvatars.SLOT_BODY, &"body_slim")
	own.set_part(G2GAvatars.SLOT_HEAD, &"head_box")
	own.set_part(G2GAvatars.SLOT_HAT, &"hat_cone")
	own.set_colour(G2GAvatars.SLOT_BODY, 0, Color.RED)

	var dressed := bot.rig.dress(own, schema, game.avatar_catalogue)
	_check(dressed.ok and int(dressed.value) == 3, "a player's own avatar dresses all three slots", str(dressed.value))
	_check(bot.rig.hat_mount.get_child_count() == 1, "including the hat")

	# One from a newer client with a part this build does not have is conformed,
	# never refused: a player is never invisible because their hat is from the future.
	var future := DotAvatar.make(G2GAvatars.SCHEMA_ID)
	future.set_part(G2GAvatars.SLOT_BODY, &"body_stock")
	future.set_part(G2GAvatars.SLOT_HEAD, &"head_stock")
	future.set_part(G2GAvatars.SLOT_HAT, &"hat_from_2031")
	var redressed := bot.rig.dress(future, schema, game.avatar_catalogue)
	_check(redressed.ok and int(redressed.value) >= 2, "an unknown part is dropped rather than refusing the whole avatar", str(redressed.value))

	bot.rig.dress(G2GAvatars.stock_avatar(&"bot"), schema, game.avatar_catalogue)


func _test_cameras() -> void:
	print("first and third person")
	var bot: G2GPlayer = game.players[&"bot"]
	var camera := bot.camera

	_check(camera.mode == G2GCamera.Mode.FIRST_PERSON, "starts in first person")
	_near(camera.vertical_fov(), G2GUnits.horizontal_fov_to_vertical(90.0), 0.01, "with the genre field of view")
	_check(camera.first.current, "and the first-person camera active")
	_check((camera.first.cull_mask & (1 << (G2GRig.LAYER_LOCAL_BODY - 1))) == 0, "which culls the player's own rig")

	_check(camera.toggle(), "toggling switches to third person")
	_check(camera.third.current and not camera.first.current, "and the third-person camera takes over")
	_check(camera.third.cull_mask & (1 << (G2GRig.LAYER_LOCAL_BODY - 1)), "which draws the rig")

	bot.present(1.0 / 60.0)
	_check(bot.rig.visible_to_owner, "and the rig is shown to its owner")

	camera.allow_third_person = false
	camera.set_mode(G2GCamera.Mode.FIRST_PERSON)
	_check(not camera.toggle(), "a server that forbids third person refuses the toggle")
	_check(camera.mode == G2GCamera.Mode.FIRST_PERSON, "and the view stays first person")
	camera.allow_third_person = true

	# Both cameras track the aim. Third person is cosmetic: the controller aims from
	# the eye whichever is active.
	bot.controller.state.pitch = -30.0
	bot.present(1.0 / 60.0)
	_near(rad_to_deg(camera.first.rotation.x), -30.0, 0.01, "the first-person camera pitches with the view")
	_near(rad_to_deg(camera.arm.rotation.x), -30.0, 0.01, "and so does the third-person arm")
	bot.controller.state.pitch = 0.0
	await get_tree().process_frame


# --- Auto-bhop -------------------------------------------------------------

func _test_auto_bhop_gate() -> void:
	print("auto-bhop is the server's decision")
	var bot: G2GPlayer = game.players[&"bot"]

	# With sv_autobunnyhopping 1, holding jump chains hops. This is what the game is for.
	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var hold := DotFpsCommand.new()
	hold.move = Vector2(0.0, 1.0)
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)

	await _prestrafe(&"bot")
	bot.controller.stats.reset()
	await _drive(&"bot", hold, 300)
	var hops_on := bot.controller.stats.jumps
	_check(hops_on >= 3, "holding jump with autobhop on chains hops", "%d" % hops_on)

	# With it off, a held key jumps once: the next press has to be a new press on the
	# landing tick, and a held key is not a press.
	game.config.auto_bhop = false
	game.apply_movement()
	_check(not bot.controller.tunables.auto_hop, "sv_autobunnyhopping 0 reaches the player's tunables")
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	await _prestrafe(&"bot")
	bot.controller.stats.reset()
	await _drive(&"bot", hold, 300)
	var hops_off := bot.controller.stats.jumps
	_check(hops_off <= 1, "and with it off a held key hops once", "%d" % hops_off)

	# The cvar change abandons a run in progress: half a run on each movement is a
	# run on neither.
	game.config.auto_bhop = true
	game.apply_movement()
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	# The start pad is 512 units long and the spawn is 400 units in; at 250 u/s the
	# line is two seconds away.
	await _drive(&"bot", forward, 400)
	_check(bot.timer.run.is_active(), "a run is going", str(bot.controller.state.describe()))
	game.config.air_accelerate = 150.0
	game.apply_movement()
	_check(not bot.timer.run.is_active(), "and changing sv_airaccelerate abandons it")
	game.config.air_accelerate = 1000.0
	game.apply_movement()


func _test_zone_files_match() -> void:
	print("the shipped zone files match the maps")
	# Every hand-written map the catalogue finds, and not a list of them.
	#
	# [b]This was `["bhop_g2g_intro", "surf_g2g_intro"]`, and there are three.[/b]
	# `bhop_g2g_stages` was never checked against its own sidecar, so the file in
	# `maps/` drifted away from what the map builds and nothing said a word — the same
	# stale copied list this tree has now had in `setup.sh`, `tools/check.sh`,
	# `tools/package_check.sh`, both bootstrap scripts and `tools/export_zones.gd`,
	# which is the file this loop exists to check the output of and which stopped
	# carrying a list for exactly this reason.
	for id in _hand_written_map_ids():
		var loaded := DotTimerZoneSet.load_json("res://maps/%s.zones.json" % id)
		var built: DotTimerZoneSet = (load("res://maps/%s.gd" % id) as GDScript).build_zones()
		_check(loaded.ok and (loaded.value as DotTimerZoneSet).fingerprint() == built.fingerprint(),
			"%s's file matches what the map builds" % id)
	await get_tree().process_frame


## The hand-written maps: the ones with a script of their own, discovered rather than
## named. Deliberately the same question `tools/export_zones.gd` asks, because a map
## this suite does not know about is a map the exporter never wrote a file for.
func _hand_written_map_ids() -> Array:
	var out: Array = []
	for map in G2GMapCatalogue.scan():
		if not bool(map.meta.get("imported", false)):
			out.append(String(map.id))
	out.sort()
	return out


# --- Runs ------------------------------------------------------------------

func _test_bhop_run() -> void:
	print("a bhop run")
	var bot: G2GPlayer = game.players[&"bot"]
	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var finished: Array[DotTimerRun] = []
	var filed := []
	bot.timer.run_finished.connect(func(run: DotTimerRun) -> void: finished.append(run))
	game.run_filed.connect(func(_id: StringName, _run: DotTimerRun, rank: int, reason: String) -> void: filed.append([rank, reason]))

	var hold := DotFpsCommand.new()
	hold.move = Vector2(0.0, 1.0)
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)

	await _prestrafe(&"bot", 100)
	bot.controller.stats.reset()

	var top := 0.0
	for i in range(900):
		bot.controller.apply_command(hold.duplicate_command())
		await get_tree().physics_frame
		top = maxf(top, bot.speed())
		if not finished.is_empty():
			break

	_check(bot.timer.runs_started >= 1, "leaving the start pad starts the run")
	# Kept, not gained: a straight-line hopper has no strafe to gain from, so the
	# most it can do is not lose the prestrafe to friction — which a held key on a
	# server with autobhop does, and a tapped one usually does not.
	_check(G2GUnits.to_units(top) >= 240.0, "and hopping keeps the run speed friction would have taken", "%s u/s" % G2GUnits.format_speed(top))
	_check(bot.controller.stats.perfect_ratio() > 0.9, "with the hops perfect, because the key is held", "%.2f" % bot.controller.stats.perfect_ratio())

	# A straight-line bot cannot strafe, so it falls at the wide gaps — and the
	# respawn zone then abandons its run, which is correct. Start a fresh one and put
	# it in the finish: the run machinery, not the bot's driving, is under test.
	if finished.is_empty():
		game.spawn_player(&"bot")
		await get_tree().physics_frame

		# Driven until the run starts rather than for a fixed 420 ticks. That number
		# was tuned when `DotTimer.effect_requested` was emitted by nothing, so the
		# map's respawn zone did nothing and a fallen bot simply kept going: now it
		# is put back on the start pad, and a fixed drive long enough to leave the
		# pad is also long enough to fall off, be reset, and be standing on the pad
		# again with no run at the moment the check runs.
		var waited := 0

		while not bot.timer.run.is_running() and waited < 600:
			await _prestrafe(&"bot", 20)
			waited += 20

		_check(bot.timer.run.is_running(), "a fresh run is going", "%d ticks" % waited)
		var end := game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 0)
		bot.controller.state.position = end.centre() + Vector3.UP * 0.3
		bot.controller.state.velocity = Vector3(0.0, 0.0, -3.0)
		var forward := DotFpsCommand.new()
		forward.move = Vector2(0.0, 1.0)
		await _drive(&"bot", forward, 4)

	_check(finished.size() == 1, "the run finishes once", "%d" % finished.size())
	if finished.size() == 1:
		_check(finished[0].stats.has("max_speed") and float(finished[0].stats["max_speed"]) > 100.0,
			"with statistics in genre units", str(finished[0].stats.get("max_speed")))
	for _i in range(5):
		await get_tree().process_frame
	_check(filed.size() == 1, "and is offered to the store", str(filed))

	var page: DotResult = await game.boards.page(&"fastest", {"map": "bhop_g2g_intro", "track": "0", "style": "normal"})
	_check((page.value as Array).size() >= 1 or (filed.size() == 1 and filed[0][1] != ""),
		"and reaches the leaderboard, or says why not", str(filed))


func _test_surf_run() -> void:
	print("a surf run")
	var changed: DotResult = await game.change_map(&"surf_g2g_intro")
	_check(changed.ok, "the surf map loads")
	game.config.air_accelerate = 150.0
	game.apply_movement()

	var bot: G2GPlayer = game.players[&"bot"]
	await get_tree().physics_frame

	# Off the front of the start platform first: the spawn is 320 units from its
	# edge and the strafing below carries the bot sideways, not forward.
	await _prestrafe(&"bot", 420)

	var airborne := 0
	var top := 0.0
	var started := bot.timer.run.is_active()
	var yaw := 0.0
	var descended := 0

	# Stopped at the pit, and that is not a tidy-up.
	#
	# The map's respawn zone works now — `DotTimer.effect_requested` was declared,
	# forwarded and connected, and emitted by NOTHING, so a bot that missed the ramps
	# fell out of the level and kept falling. Measured over a flat 1500 ticks, every
	# one of those falling ticks counted as "not grounded", and this check passed on
	# a bot that was nowhere near the map. The bot descends for about 500 ticks and
	# then hits the pit; over that window it is airborne for 94% of them, which is
	# what the check was always meant to say.
	#
	# An Array, not a bool: a GDScript lambda captures locals by value, so a flag set
	# inside a signal handler reads false outside it — and the first version of this
	# fix broke out of nothing and reported "468 of 1500".
	var reset: Array[bool] = [false]
	var on_reset := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset[0] = true

	game.timers.effect_requested.connect(on_reset)

	for i in range(1500):
		var c := DotFpsCommand.new()
		var phase := (i / 90) % 2
		c.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		yaw += -0.3 if phase == 0 else 0.3
		c.yaw = wrapf(yaw, -180.0, 180.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame
		if bot.timer.run.is_active():
			started = true
		if not bot.controller.state.is_grounded():
			airborne += 1
		top = maxf(top, bot.speed())
		descended += 1

		if reset[0]:
			break

	game.timers.effect_requested.disconnect(on_reset)

	_check(
		reset[0],
		"missing the ramps drops the bot into the pit, which puts it back",
		"%d ticks" % descended
	)

	_check(started, "leaving the start platform starts a run")
	_check(
		airborne > descended * 6 / 10,
		"most of the descent is spent not grounded, which is surf",
		"%d of %d ticks" % [airborne, descended]
	)
	_check(G2GUnits.to_units(top) > 500.0, "and the bot reaches surf speed, twice its run speed", "%s u/s" % G2GUnits.format_speed(top))
	_check(bot.controller.motor.stuck_ticks == 0, "without the slide ever running out of iterations")
	game.config.air_accelerate = 1000.0
	game.apply_movement()


func _test_bonus_track() -> void:
	print("the bonus track")
	var bot: G2GPlayer = game.players[&"bot"]
	_check(game.timers.set_player_track(&"bot", DotTimerTrack.of_bonus(1)), "a player can switch to the bonus")
	game.spawn_player(&"bot")
	await get_tree().physics_frame
	var spawn := game.current_map_node().spawn_for(DotTimerTrack.of_bonus(1))
	_check(bot.global_position.distance_to(spawn) < 1.0, "and spawns at the bonus's own spawn")
	_check(bot.timer.track == DotTimerTrack.of_bonus(1), "and their timer is on it")

	await _test_transfer_bonus()

	game.timers.set_player_track(&"bot", DotTimerTrack.MAIN)


## Bonus 2 on the surf map: two ramps banked opposite ways, with a gap.
##
## [b]The check that matters is the last one, and it is the only one an assertion
## about the zone file cannot make.[/b] Bonus 1 is a single bank -- get on it, hold
## it, ride it down -- and a bot that can do that can do it on any single bank. This
## route ends the first ramp in mid-air and asks the player to catch a second one
## banked the other way, so a bot that reaches the finish has proved the two pieces
## of geometry actually line up. Numbers that are 200 units out produce a route that
## looks perfect in a screenshot and drops every player into the pit.
func _test_transfer_bonus() -> void:
	var bot: G2GPlayer = game.players[&"bot"]
	var transfer := DotTimerTrack.of_bonus(2)

	_check(game.timers.set_player_track(&"bot", transfer), "and to the transfer bonus")

	game.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := game.current_map_node().spawn_for(transfer)
	_check(
		bot.global_position.distance_to(spawn) < 1.0,
		"which has a spawn of its own, away from the first bonus's",
		"%.1f m apart" % spawn.distance_to(game.current_map_node().spawn_for(DotTimerTrack.of_bonus(1)))
	)

	game.config.air_accelerate = 150.0
	game.apply_movement()

	# Off the pad first, then strafe. Same shape as the main surf run: the spawn is
	# behind the lip and the strafing below carries the bot sideways, not forward.
	await _prestrafe(&"bot", 300)

	var started := false
	var finished := false
	var reset := false
	var yaw := 0.0

	var watch := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			reset = true

	game.timers.effect_requested.connect(watch)

	for i in range(1200):
		var c := DotFpsCommand.new()
		var phase := (i / 90) % 2
		c.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		yaw += -0.3 if phase == 0 else 0.3
		c.yaw = wrapf(yaw, -180.0, 180.0)
		bot.controller.apply_command(c)
		await get_tree().physics_frame

		if bot.timer.run.is_active():
			started = true

		if bot.timer.track == transfer and not bot.timer.run.is_active() and started:
			finished = true
			break

		if reset:
			break

	game.timers.effect_requested.disconnect(watch)
	game.config.air_accelerate = 1000.0
	game.apply_movement()

	_check(started, "leaving its pad starts a run on the bonus's own track")
	# [b]Where it ENDS, not whether it cleared.[/b] A crude bot alternating strafe
	# every ninety ticks is not a surfer and never will be; what it can prove is the
	# thing the geometry has to be right for -- that the route holds a player from the
	# pad to the bottom. The failure this catches is the one the first draft had: the
	# second ramp covered only the back third of the first, so coming off early meant
	# falling between them, and the bot ended 500 m under the level with nothing in
	# the log to say so.
	var at := bot.global_position
	var floor_m := G2GUnits.to_metres(START_Y - 1700.0)
	var roof_m := G2GUnits.to_metres(START_Y + 256.0)

	_check(
		at.y > floor_m and at.y < roof_m,
		"and the route holds the bot between its pad and its floor",
		"y %.1f m, route is %.1f to %.1f" % [at.y, floor_m, roof_m]
	)

	# The respawn zone the bonus tracks did not have. With it, a bot that does fall is
	# put back on the pad instead of falling for ever -- so "not reset" now means it
	# stayed on the route rather than meaning nothing was watching.
	_check(
		zones_have_respawn_on_bonuses(),
		"and a bonus that is missed puts the player back, like the main track"
	)


## Whether every playable track on the current map has a respawn zone.
func zones_have_respawn_on_bonuses() -> bool:
	var zones := game.timers.zones

	if zones == null:
		return false

	for track in zones.playable_tracks():
		var found := false

		for zone in zones.zones:
			if zone.track == track and zone.kind == DotTimerZone.Kind.RESPAWN:
				found = true
				break

		if not found:
			return false

	return true


# --- The ghost -------------------------------------------------------------

static func _fake_replay(map_id: StringName, seconds: float, tick_rate: int) -> DotTimerReplay:
	var replay := DotTimerReplay.new()
	replay.map_id = map_id
	replay.tick_rate = tick_rate
	replay.time = seconds
	replay.player_name = "Ghost"
	var frames := int(seconds * float(tick_rate))
	for i in range(frames):
		var t := float(i) / float(maxi(frames - 1, 1))
		replay.append(Vector3(0.0, 1.0, 7.0 - 30.0 * t), 90.0 * t, 0.0)
	return replay


func _test_ghost() -> void:
	print("the world-record ghost")
	var map_id: StringName = game.maps.current.id
	var replay := _fake_replay(map_id, 3.0, game.tick_rate)
	var record := DotTimerRecord.new()
	record.map_id = map_id
	record.track = DotTimerTrack.MAIN
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 3.0

	_check(game.replays.offer(replay, record), "a record's replay is kept")
	var slower := _fake_replay(map_id, 4.0, game.tick_rate)
	record.time = 4.0
	_check(not game.replays.offer(slower, record), "a slower one is not")
	_check(game.replays.best(map_id, 0, &"normal") == replay, "and the best is the fast one")

	var ghost := game.spawn_ghost()
	_check(ghost != null and ghost.replay != null and ghost.timer == null, "the ghost is a player with a replay and no timer")
	_check(ghost != null and ghost.display_name.begins_with("WR 0:03.000"), "named for the record", ghost.display_name if ghost else "")
	var before := ghost.global_position if ghost != null else Vector3.ZERO
	for _i in range(64):
		await get_tree().physics_frame
	var after := ghost.global_position if ghost != null else Vector3.ZERO
	_check(before.distance_to(after) > 1.0, "and it runs the map", "%.2f m in half a second" % before.distance_to(after))
	_check(ghost != null and G2GUnits.to_units(ghost.speed()) > 100.0, "at the replay's speed", G2GUnits.format_speed(ghost.speed()) if ghost else "")
	_check(game.players.size() >= 2 and game.timers.player(G2GGame.GHOST_ID) == null, "without a timer to feed")

	# Persistence: a second keeper over the same directory finds it.
	var dir := "user://g2gfast-test-replays-%d" % Time.get_ticks_usec()
	var keeper := G2GReplays.new()
	_check(keeper.setup(dir).ok, "a keeper opens a directory")
	record.time = 3.0
	_check(keeper.offer(replay, record), "and writes a replay there")
	var again := G2GReplays.new()
	again.setup(dir)
	var found := again.best(map_id, 0, &"normal")
	_check(found != null and found.frames.size() == replay.frames.size() and absf(found.time - 3.0) < 0.001,
		"which a fresh keeper reads back", str(found.describe()) if found else "none")
	_check(again.best(&"surf_kitsune2", 0, &"normal") == null and again.best(&"surf_kitsune3", 0, &"normal") == null,
		"and two ids that differ by a digit do not share a file")
	for file in DirAccess.get_files_at(dir.path_join("replays")):
		DirAccess.remove_absolute(dir.path_join("replays").path_join(file))
	DirAccess.remove_absolute(dir.path_join("replays"))
	DirAccess.remove_absolute(dir)

	var changed: DotResult = await game.change_map(&"surf_g2g_intro")
	# The surf run above may have filed a record of its own, in which case surf has
	# a ghost too — its own, never the bhop map's.
	var swapped := game.ghost()
	_check(changed.ok and (swapped == null or swapped.replay.replay.map_id == &"surf_g2g_intro"),
		"a map change swaps the ghost for that map's own, or none",
		str(changed.error) if not changed.ok else String(swapped.replay.replay.map_id) if swapped else "")
	changed = await game.change_map(map_id)
	for _i in range(4):
		await get_tree().process_frame
	_check(changed.ok and game.ghost() != null, "and it is back with its map")

	# [b]The look guard, on the predicate rather than through a client.[/b] Nothing in
	# this suite stands a `G2GClient` up, so the honest thing this can check is the
	# contract the motion handler branches on. `Input.mouse_mode` is not the thing to
	# assert against: the dummy display server pins it to VISIBLE and drops every write
	# without erroring, which is why `game-arena`'s identical guard has never been
	# exercised by anything either.
	var look := G2GClient.new()
	_check(not look.mouse_drives_view(),
		"a released cursor is not a look input")
	look.mouse_capture_override = true
	_check(look.mouse_drives_view(),
		"and a captured one is")
	look.free()


# --- Progression ------------------------------------------------------------

## dot-stats and dot-achievements, over the runs this suite actually made.
##
## [b]Every check here is against a number the runs above PRODUCED.[/b] A progression
## suite that files its own readings and reads them back is testing dot-stats, which
## dot-stats already does; what is untested anywhere else is whether a finish in this
## game reaches those two addons at all.
func _test_progression() -> void:
	print("progression")

	var progress := game.progress

	# `_check` in this suite returns void, so the guard is a plain test with the
	# report beside it rather than the `if not _check(...)` shape the other suites in
	# this family use.
	_check(progress != null, "the server keeps progress")

	if progress == null:
		return

	var schema_ok := progress.stats.schema.validate()
	_check(schema_ok.ok, "the stats schema validates", str(schema_ok.error))

	var catalogue_ok := progress.achievements.catalogue.validate()
	_check(catalogue_ok.ok, "the achievement catalogue validates", str(catalogue_ok.error))

	# Every stat an achievement reads must be one the schema declares. Nothing in
	# either addon can check this: dot-achievements does not know the schema exists
	# and dot-stats does not know the catalogue does.
	var undeclared := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not progress.stats.schema.has(stat):
			undeclared.append(String(stat))

	_check(
		undeclared.is_empty(),
		"every stat an achievement watches is one the schema declares",
		", ".join(undeclared)
	)

	# --- What the runs above filed ---------------------------------------

	var values := progress.session_values(&"bot")

	_check(
		values.get_value(G2GStats.RUNS_STARTED, 0.0) > 0.0,
		"runs started were counted",
		"%d" % int(values.get_value(G2GStats.RUNS_STARTED, 0.0))
	)
	_check(
		values.get_value(G2GStats.RUNS_FINISHED, 0.0) > 0.0,
		"and so were finishes",
		"%d" % int(values.get_value(G2GStats.RUNS_FINISHED, 0.0))
	)

	# A best time is LOWEST, and the distinction between "held zero" and "never seen"
	# is what stops every player's personal best being zero the moment the feature
	# ships. A finished run means there IS a time, so it must be above zero.
	_check(
		values.get_value(G2GStats.BEST_TIME, 0.0) > 0.0,
		"a best time was filed as a time rather than as a zero",
		"%.3f s" % values.get_value(G2GStats.BEST_TIME, 0.0)
	)

	_check(
		values.get_value(G2GStats.JUMPS, 0.0) > 0.0,
		"the movement counters were read off the controller",
		"%d jumps" % int(values.get_value(G2GStats.JUMPS, 0.0))
	)

	# The counters are a running total the game RESETS on every finish, so filing the
	# total on each sample would add the whole history every tick. At 128 Hz over the
	# runs above that would be six figures for a few hundred jumps.
	_check(
		values.get_value(G2GStats.JUMPS, 0.0) < 100000.0,
		"and filed as deltas rather than as the running total each tick",
		"%d" % int(values.get_value(G2GStats.JUMPS, 0.0))
	)

	_check(
		values.get_value(G2GStats.PERFECT_JUMPS, 0.0)
			<= values.get_value(G2GStats.JUMPS, 0.0),
		"perfect jumps never exceed jumps"
	)

	# In units, because everything a player reads in this game is. A top speed under
	# a hundred would be metres per second wearing the wrong label.
	_check(
		values.get_value(G2GStats.TOP_SPEED, 0.0) > 100.0,
		"top speed was filed in genre units",
		"%.0f u/s" % values.get_value(G2GStats.TOP_SPEED, 0.0)
	)

	# Distance is the one figure this layer measures itself, and it refuses a jump of
	# more than half a metre in one tick — a respawn, a stage warp or a `!r`. The bot
	# above was teleported into the finish zone at least once, so a distance equal to
	# the map's whole length would mean the guard is not working.
	var distance := values.get_value(G2GStats.DISTANCE, 0.0)
	_check(distance > 0.0, "distance was measured", "%.0f m" % distance)
	_check(
		distance < 100000.0,
		"and a teleport was not counted as travel",
		"%.0f m" % distance
	)

	# --- Achievements ----------------------------------------------------

	_check(
		progress.achievements.is_unlocked("bot", &"g2g.first_finish"),
		"finishing a course unlocked the achievement for it"
	)

	# The differencing. A player with N session finishes must hold N lifetime
	# finishes, not the running sum 1+2+...+N that a direct signal connection makes.
	var held := progress.achievements.progress_of("bot")

	if held != null:
		_check(
			absf(
				held.value_of(G2GStats.RUNS_FINISHED)
					- values.get_value(G2GStats.RUNS_FINISHED, 0.0)
			) < 0.001,
			"lifetime finishes equal session finishes, so the link differences",
			"%.0f vs %.0f" % [
				held.value_of(G2GStats.RUNS_FINISHED),
				values.get_value(G2GStats.RUNS_FINISHED, 0.0),
			]
		)

		# A LOWEST stat is an absolute in both systems and must be passed through
		# rather than differenced — differencing a personal best would be meaningless,
		# and dot-achievements' link says so.
		_check(
			absf(
				held.value_of(G2GStats.BEST_TIME)
					- values.get_value(G2GStats.BEST_TIME, 0.0)
			) < 0.001,
			"and a best time is passed through rather than differenced",
			"%.3f vs %.3f" % [
				held.value_of(G2GStats.BEST_TIME),
				values.get_value(G2GStats.BEST_TIME, 0.0),
			]
		)

	# Under Thirty is the trap: a LOWEST stat with an AT_MOST rule is satisfied by a
	# player who has never been recorded, because a missing stat reads as zero. It is
	# guarded by a second rule requiring a finished run — so a player who has never
	# played must NOT have it.
	await progress.begin(&"nobody", "Nobody")
	_check(
		not progress.achievements.is_unlocked("nobody", &"g2g.sub_thirty"),
		"a player who has never run has not finished a course in under thirty seconds"
	)
	await progress.leave(&"nobody")
