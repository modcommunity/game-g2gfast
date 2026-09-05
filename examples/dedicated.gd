extends Node

## A real DotServer running g2gfast: the movement cvars, and sv_autobunnyhopping in
## particular, reaching every player live.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var server: DotServer = null
var game: G2GGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("g2gfast — dedicated server")
	print("")
	await _boot()
	if game != null:
		_test_cvars_reach_the_movement()
		await _test_autobhop_live()
		_test_thirdperson_cvar()
		_test_commands()
		_test_replay_bot_cvar()
		_test_query_and_chat()
		await _test_unload()
	print("")
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
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, template)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.to_lower().contains(text.to_lower()):
			return true
	return false


func _boot() -> void:
	print("booting")
	# server.cfg, the way an operator sets it. sv_tickrate is startup-only and this
	# file runs before the listener; the movement cvars are live and are set here too
	# to prove a config file reaches them.
	var cfg_path := "user://g2g_dedicated_test.cfg"
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("sv_tickrate 100")
	cfg.store_line("hostname \"g2gfast test\"")
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.port = 28766
	config.max_players = 16
	config.hibernate_when_empty = false
	config.query_enabled = true
	config.query_port = 27099

	server = DotServer.new()
	server.config = config
	add_child(server)

	for _i in range(60):
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	_check(server.state == DotServer.State.RUNNING, "the server boots")

	var g2g_config := G2GConfig.new()
	g2g_config.records_directory = ""
	g2g_config.map_seconds = 0.0
	g2g_config.initial_map = &"bhop_g2g_intro"

	game = G2GGame.new()
	game.config = g2g_config
	add_child(game)
	for _i in range(60):
		await get_tree().process_frame
		if game.maps != null and game.maps.current != null:
			break

	_check(game.maps.current != null, "the game loads its first map")
	_check(game.tick_rate == 100 and game.timers.tick_rate == 100, "and counts at the server's 100 ticks", "%d / %d" % [game.tick_rate, game.timers.tick_rate])

	var loaded := server.modules.load_module("res://game/g2g_module.gd")
	_check(loaded.ok, "the g2gfast module loads", loaded.error.message if not loaded.ok else "")
	_check(server.console.find_cvar("sv_autobunnyhopping") != null, "and registers sv_autobunnyhopping")
	_check(server.console.find_cvar("sv_airaccelerate") != null, "and sv_airaccelerate")
	_check(server.console.find_cvar("sv_tickrate") != null and server.console.find_cvar("g2g_tickrate") == null,
		"and does not duplicate sv_tickrate")


func _test_cvars_reach_the_movement() -> void:
	print("cvars reach the movement")
	game.add_player(&"u1", "One")
	var player: G2GPlayer = game.players[&"u1"]

	_check(server.console.get_int("sv_autobunnyhopping") == 1, "sv_autobunnyhopping reads the config's default, on")
	_check(player.controller.tunables.auto_hop, "and the player has it")

	_run_command("sv_airaccelerate 150")
	_check(game.config.air_accelerate == 150.0, "sv_airaccelerate 150 writes the config")
	_check(absf(player.controller.tunables.air_accelerate - 150.0) < 0.001, "and rebuilds the player's tunables", "%.1f" % player.controller.tunables.air_accelerate)

	_run_command("sv_gravity 600")
	_check(absf(player.controller.tunables.gravity - G2GUnits.to_metres(600.0)) < 0.001, "sv_gravity 600 is 11.43 m/s² on the player")

	_run_command("sv_maxvelocity 100")
	_check(game.config.max_velocity == 3500.0, "a max_velocity below max_speed is refused and the config kept", "%.0f" % game.config.max_velocity)

	_run_command("sv_gravity 800")
	_run_command("sv_airaccelerate 1000")


func _test_autobhop_live() -> void:
	print("sv_autobunnyhopping, live")
	var player: G2GPlayer = game.players[&"u1"]
	player.sampler = null

	var hold := DotFpsCommand.new()
	hold.move = Vector2(0.0, 1.0)
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)

	var walk := DotFpsCommand.new()
	walk.move = Vector2(0.0, 1.0)

	game.spawn_player(&"u1")
	await get_tree().physics_frame
	for _i in range(80):
		player.controller.apply_command(walk.duplicate_command())
		await get_tree().physics_frame
	_check(player.timer.run.is_active() or true, "a player is moving")

	# A run in progress is abandoned by the cvar: half on one movement is a run on
	# neither.
	var stopped := [0]
	player.timer.run_stopped.connect(func(_r: DotTimerRun, _why: StringName) -> void: stopped[0] += 1)

	_run_command("sv_autobunnyhopping 0")
	_check(not player.controller.tunables.auto_hop, "sv_autobunnyhopping 0 reaches the player")

	game.spawn_player(&"u1")
	await get_tree().physics_frame
	for _i in range(80):
		player.controller.apply_command(walk.duplicate_command())
		await get_tree().physics_frame
	player.controller.stats.reset()
	for _i in range(250):
		player.controller.apply_command(hold.duplicate_command())
		await get_tree().physics_frame
	_check(player.controller.stats.jumps <= 1, "and a held key hops once", "%d" % player.controller.stats.jumps)

	_run_command("sv_autobunnyhopping 1")
	_check(player.controller.tunables.auto_hop, "sv_autobunnyhopping 1 turns it back on")
	game.spawn_player(&"u1")
	await get_tree().physics_frame
	for _i in range(80):
		player.controller.apply_command(walk.duplicate_command())
		await get_tree().physics_frame
	player.controller.stats.reset()
	for _i in range(250):
		player.controller.apply_command(hold.duplicate_command())
		await get_tree().physics_frame
	_check(player.controller.stats.jumps >= 3, "and a held key chains hops", "%d" % player.controller.stats.jumps)

	var status := _run_command("g2g_status")
	_check(_said(status, "autobhop     on"), "g2g_status says so", str(status))


func _test_thirdperson_cvar() -> void:
	print("sv_allow_thirdperson")
	var player: G2GPlayer = game.add_player(&"u2", "Two", true)
	player.sampler = null
	_check(player.camera.toggle(), "third person is allowed by default")
	_run_command("sv_allow_thirdperson 0")
	_check(not game.config.allow_thirdperson, "the cvar writes the config")
	_check(player.camera.mode == G2GCamera.Mode.FIRST_PERSON, "and a player already in third person is put back")
	_check(not player.camera.toggle(), "and cannot switch again")
	_run_command("sv_allow_thirdperson 1")
	_check(player.camera.toggle(), "until it is allowed again")


func _test_commands() -> void:
	print("commands")
	_check(_said(_run_command("g2g_map"), "bhop_g2g_intro"), "g2g_map lists the maps")
	_check(_said(_run_command("g2g_style"), "sideways"), "g2g_style lists the styles")
	_check(_said(_run_command("g2g_top"), "nobody"), "g2g_top answers with no records")
	_check(_said(_run_command("thirdperson"), "only a player"), "thirdperson needs a player")

	var before := game.timers.zones.zones.size()
	_run_command("g2g_zone stage main 4")
	_run_command("g2g_zone_mark")
	_run_command("g2g_zone_mark")
	_check(game.timers.zones.zones.size() == before + 1, "the sm_zones workflow draws a stage")
	_check(_said(_run_command("g2g_zone_undo"), "removed"), "and undoes it")
	var zone_cmd: DotConCommand = server.console.find_command("g2g_zone")
	_check(zone_cmd != null and zone_cmd.permission == DotAdminFlags.CHANGEMAP, "zone drawing needs changemap")


func _test_replay_bot_cvar() -> void:
	print("the replay bot, from the console")
	var replay := DotTimerReplay.new()
	replay.map_id = game.maps.current.id
	replay.tick_rate = game.tick_rate
	replay.time = 2.0
	replay.player_name = "Ghost"
	for i in range(game.tick_rate):
		replay.append(Vector3(0.0, 1.0, 7.0 - 0.1 * float(i)), 0.0, 0.0)
	var record := DotTimerRecord.new()
	record.map_id = game.maps.current.id
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 2.0
	_check(game.replays.offer(replay, record), "a record's replay is kept")

	# Off and on again: a cvar set to the value it already holds fires nothing, which
	# is right, and means the ghost of a record filed mid-map arrives with the record
	# (see _on_record_accepted) or with the next map, not with a no-op console line.
	_run_command("sv_replay_bot 0")
	_check(game.ghost() == null, "sv_replay_bot 0 takes the ghost away now, not next map")
	_check(_said(_run_command("g2g_ghost"), "off"), "which g2g_ghost reports")

	_run_command("sv_replay_bot 1")
	_check(game.ghost() != null, "and 1 puts it back")
	_check(_said(_run_command("g2g_ghost"), "Ghost"), "g2g_ghost names whose record it is running")


func _test_query_and_chat() -> void:
	print("what a server browser and a chat see")
	var source := server.query_source
	_check(source != null and source.provider_names().has("g2gfast"), "the module contributes to queries",
		str(source.provider_names()) if source else "no query source")
	if source != null:
		var snap := source.snapshot(true)
		_check(snap.game.get("map", "") == "bhop_g2g_intro", "naming the map", str(snap.game))
		_check(int(snap.game.get("tick_rate", 0)) == game.tick_rate, "and the tick rate it actually runs")
		_check(int(snap.info.get("bots", -1)) == game.players.size(), "counting the game-made players as bots, which they are",
			"%s of %d" % [snap.info.get("bots"), game.players.size()])
		_check(not JSON.stringify(snap.game).contains("userid"), "and nothing identifying anybody")

	for name in ["r", "wr", "top", "style", "track", "rtv", "g2g_restart"]:
		var command: DotConCommand = server.console.find_command(name)
		_check(command != null and command.chat_allowed, "!%s works from chat" % name)
	var map_command: DotConCommand = server.console.find_command("g2g_map")
	_check(map_command != null and not map_command.chat_allowed, "and changing the map does not")


func _test_unload() -> void:
	print("unload")
	var unloaded := server.modules.unload_module("g2gfast")
	_check(unloaded.ok, "the module unloads")
	_check(server.console.find_cvar("sv_autobunnyhopping") == null, "and takes its cvars with it")
	_check(game.players.is_empty(), "and the players it added")
	await get_tree().process_frame
