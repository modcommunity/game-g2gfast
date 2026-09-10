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
		await _test_services()
		_test_vote()
		_test_modes()
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
	# All three modes on, so the layers exist and can be flipped. They are built
	# whether or not they are enabled — the cvars flip a layer that already exists —
	# so this is what says "this server booted with them", not "they are running".
	g2g_config.deathmatch = true
	g2g_config.hunters = true
	g2g_config.placeable_props = true

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


# --- The rest of the server -------------------------------------------------

## Chat, voice, moderation and the identity chain, on a real server.
##
## [b]Each of these five passes its own suite with a stub host.[/b] What is untested
## anywhere else is that they can all be brought up in one process against one
## [DotServer] — and specifically that dot-moderation is up before the two routers that
## look up the registry name it publishes, because a router that started first would
## find nothing, warn once, and enforce no gag for the life of the server.
func _test_services() -> void:
	print("")
	print("chat, voice and moderation")

	var module := server.modules.get_module("g2gfast")
	_check(module != null, "the module is there")

	if module == null:
		return

	var services: G2GServices = module.get("services")
	_check(services != null, "the services layer is up")

	if services == null:
		return

	_check(services.chat != null, "chat is running")
	_check(services.voice != null, "voice is running")
	_check(services.moderation != null, "moderation is running")

	_check(
		DotRegistry.get_service(DotModerationManager.MUTE_SERVICE) != null,
		"and it published a mute source for the two routers to find"
	)
	_check(
		DotRegistry.get_service(DotModerationManager.BAN_SERVICE) != null,
		"and a ban source for the admission check"
	)

	# Four channels, and the one that is about this genre is `running`: everybody who
	# is mid-run. It is a MEMBERS channel, and the membership rule is a thing only
	# this game knows — which is exactly why dot-chat asks rather than deciding.
	_check(
		services.chat.has_channel(G2GServices.CH_RUNNING),
		"there is a channel for the people who are mid-run"
	)

	var running := services.chat.channel(G2GServices.CH_RUNNING)
	_check(
		running != null and running.scope == DotChatChannel.Scope.MEMBERS,
		"and it really is decided by membership rather than by radius"
	)

	_check(services.chat.rules.escape_markup, "markup is escaped")

	var dirty := DotChatFilter.sanitise(
		"[color=red]server[/color]: free stuff", services.chat.rules
	)
	_check(
		dirty.ok and not String(dirty.value).contains("[color=red]"),
		"and a player cannot write a colour tag",
		str(dirty.value)
	)

	# A gag against the PERSON. dot-server's is two booleans on a session object, and
	# a session dies with its connection — so a muted player reconnects and talks.
	var subject := DotPunishmentSubject.for_uid("7788")
	var issued: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "suite", 3600
	)
	_check(issued.ok, "a gag can be issued", str(issued.error))
	_check(
		services.moderation.is_gagged_key(subject),
		"and it is held against the person rather than the connection"
	)

	var record: DotPunishment = issued.value if issued.ok else null

	if record != null:
		var lifted: DotResult = await services.moderation.revoke(
			record.id, "suite", "over"
		)
		_check(lifted.ok, "and lifted again", str(lifted.error))

	# --- Identity --------------------------------------------------------

	var identity: G2GIdentity = module.get("identity")
	_check(identity != null, "the identity layer is up")

	if identity == null:
		return

	_check(identity.platform != null, "with a platform hub")
	_check(
		DotRegistry.get_node_service(DotPlatformHub.SERVICE) != null,
		"registered, which is how dot-platform's module finds it"
	)
	_check(
		server.modules.has_module("platform"),
		"and dot-platform's own module is loaded beside this one"
	)

	# The avatar manager validates against the GAME's schema, not a second one.
	# `G2GRig.dress` conforms every document to it, so a manager on a different schema
	# would accept avatars the rig then silently rewrote.
	_check(
		identity.avatars != null and identity.avatars.schema.id == G2GAvatars.SCHEMA_ID,
		"and the avatar manager validates against the game's own schema"
	)


## dot-vote over this server's map catalogue.
##
## [b]This game already had a rock-the-vote and it was not one.[/b]
## `DotMapTimeLimit` counts votes against a fraction and expires the map: a countdown
## and a tally. What a records community runs is a ballot — nominations, seconding, an
## instant runoff, a cooldown, an extend option — and that is dot-vote.
func _test_vote() -> void:
	print("")
	print("the vote")

	var module := server.modules.get_module("g2gfast")
	var vote: G2GVote = module.get("vote") if module != null else null

	_check(vote != null, "the vote is up")

	if vote == null:
		return

	_check(vote.source != null and vote.source.is_usable(), "with something to vote for")
	_check(
		vote.director.rules.method == DotVoteRules.Method.INSTANT_RUNOFF,
		"counted by instant runoff rather than plurality"
	)
	_check(
		vote.director.rules.include_extend,
		"and a map can be extended rather than only replaced"
	)

	# `begin_on_apply` off is what stops one play being counted twice. Two entries in
	# the history for one play is a "last five" cooldown that is quietly two or three.
	_check(
		not vote.director.begin_on_apply,
		"the director does not announce a change the host already announces"
	)

	# The ghost is a player in every sense that matters to the game and none that
	# matters to a vote. Counting it would let a one-player server pass a quorum of
	# two, and let it rock the vote on its own.
	game.spawn_ghost()

	var voters := vote._player_count()
	var ghosted := game.players.has(G2GGame.GHOST_ID)

	# [b]The count, not zero.[/b] The first version of this asserted an empty server
	# and the sections above leave players on it — so it failed at "2 voters with 3
	# players", which is the exclusion working. What it has to say is that the ghost
	# is the one player that is not a voter.
	_check(
		voters == game.players.size() - (1 if ghosted else 0),
		"the record ghost is not counted as a voter",
		"%d voters, %d players, ghost %s" % [
			voters, game.players.size(), "up" if ghosted else "absent"
		]
	)

	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(
		opened.ok or opened.error != null,
		"a vote can be asked for and answers either way",
		"" if opened.ok else opened.error.message
	)

	if opened.ok:
		_check(vote.is_voting(), "and the ballot opens")
		vote.director.close_vote()
		_check(not vote.is_voting(), "and closes again")


## The three modes, and the cvars that flip them.
##
## [b]Each layer is built whether or not it is enabled, and the cvar flips it.[/b] A
## layer constructed on the cvar instead would be constructed under live players,
## which is where the interesting failures are — and it would have to be torn down
## again on the way back.
func _test_modes() -> void:
	print("")
	print("deathmatch, hunters and blocks")

	_check(game.combat != null, "the deathmatch layer is built")
	_check(game.hunters != null, "the hunters are built")
	_check(game.props != null, "the blocks are built")

	for name in ["sv_deathmatch", "sv_hunters", "sv_props"]:
		_check(server.console.find_cvar(name) != null, "%s is a cvar" % name)

	if game.combat != null:
		_check(game.combat.enabled, "deathmatch starts on, because the config said so")

		_run_command("sv_deathmatch 0")
		_check(not game.combat.enabled, "and sv_deathmatch 0 turns it off live")

		_run_command("sv_deathmatch 1")
		_check(game.combat.enabled, "and back on again")

		# The match must not carry a time limit of its own. The MAP's clock ends the
		# map; a second clock underneath it that ends the match is two authorities
		# over one question, and dot-vote's director already owns the first.
		_check(
			game.combat.match_node.rules.time_limit_sec == 0.0,
			"the match has no clock of its own"
		)

		# A run and a fight at the same time. The layer adds hitboxes, health and an
		# arsenal and takes nothing away — a player who never presses fire plays
		# exactly the game they played before.
		var runner := game.add_player(&"u4242", "Runner")
		_check(runner != null, "a player joins")

		if runner != null:
			_check(
				game.combat.health_of(&"u4242") != null,
				"and is shootable in deathmatch"
			)
			_check(
				runner.timer != null,
				"and still has a timer, because the run is the point"
			)

			# The ghost is deliberately not armed: it is a replay, it cannot be hurt,
			# and registering it would put a name on the scoreboard that never dies
			# and never leaves.
			_check(
				game.combat.health_of(G2GGame.GHOST_ID) == null,
				"the record ghost is not on the scoreboard"
			)

			game.remove_player(&"u4242")

	if game.hunters != null:
		# A timer map is a critical path — start pad, stage lines, end zone — and
		# `DotNpcDirectorFlow` is exactly that as a thing a position can be measured
		# along. So there is no navigation graph and the route is the map's zones.
		_check(
			game.hunters.flow != null and game.hunters.flow.has_route(),
			"the hunt route was built from the map's own zones"
		)
		_check(
			game.hunters.flow != null and game.hunters.flow.length() > 1.0,
			"and it has a length",
			"%.1f m" % (game.hunters.flow.length() if game.hunters.flow != null else 0.0)
		)

		var somewhere := game.hunters.patrol_point(0.5)
		_check(
			somewhere != Vector3.ZERO,
			"and a hunter with nothing to chase has somewhere on it to walk to"
		)

		_run_command("sv_hunters 0")
		_check(not game.hunters.enabled, "sv_hunters 0 turns the hunt off")
		_check(game.hunters.count() == 0, "and takes the hunters away now")

		_run_command("sv_hunters 1")
		_check(game.hunters.enabled, "and back on again")

	if game.props != null:
		var placed := game.props.place(
			&"u1", G2GProps.BLOCK, Vector3(0.0, 2.0, 0.0), true
		)
		_check(placed != null, "an admin can place a block")
		_check(game.props.count() == 1, "and it is in the world")

		if placed != null:
			# The catalogue's mass, on the body. dot-props puts it there at spawn
			# rather than leaving it to whatever the scene was saved with.
			var body := placed.body()
			_check(
				body != null and absf(body.mass - 200.0) < 0.01,
				"with the catalogue's mass rather than the scene's",
				"%.0f kg" % (body.mass if body != null else -1.0)
			)
			# Frozen, which is the opposite default from a sandbox's: a practice
			# block that rolls away is not a practice block.
			_check(
				body != null and body.freeze,
				"and frozen where it was put"
			)

		# The rule that makes the feature safe to ship: a board with one time set
		# over a placed block is a board nobody trusts.
		_check(
			game.props.taints_records(),
			"and a run made while anything is placed cannot be ranked"
		)

		_check(game.props.undo(&"u1"), "undo takes it back")
		_check(
			not game.props.taints_records(),
			"and records are rankable again once the course is clear"
		)


func _test_unload() -> void:
	print("unload")
	var unloaded := server.modules.unload_module("g2gfast")
	_check(unloaded.ok, "the module unloads")
	_check(server.console.find_cvar("sv_autobunnyhopping") == null, "and takes its cvars with it")
	_check(game.players.is_empty(), "and the players it added")
	await get_tree().process_frame
