extends DotModule

## Binds a [G2GGame] to a [DotServer]: the movement cvars, and the commands.
##
## [b]The cvars are the ones those operators already know[/b], with the
## same names and the same units — [code]sv_autobunnyhopping[/code],
## [code]sv_airaccelerate[/code], [code]sv_gravity[/code] and the rest. Each writes
## the game's [G2GConfig] and rebuilds the movement for every player, abandoning
## their runs, because a run half on one movement and half on another is not a run.
##
## [code]sv_tickrate[/code] is dot-server's own and is deliberately not duplicated.

const CHANNEL := "g2g.module"

var game: G2GGame = null
var net: DotNetManager = null
var bridge: G2GNetBridge = null
var _painters: Dictionary = {}
var _tick: int = 0
var _joined: Dictionary = {}

const SNAPSHOT_RATE := 32


func _module_name() -> String:
	return "g2gfast"

func _module_version() -> String:
	return "0.1.0"

func _module_description() -> String:
	return "Bunny-hop and surf timer in the competitive-shooter shape."

func _module_author() -> String:
	return "dot"


func _module_load() -> DotResult:
	game = DotRegistry.get_node_service(G2GGame.SERVICE) as G2GGame
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "No G2GGame is registered.")

	var netted := _build_netcode()
	if not netted.ok:
		return netted

	# --- Movement cvars, in genre units --------------------------------------
	_movement_cvar("sv_autobunnyhopping", "auto_bhop", "Hold jump to hop.")
	_movement_cvar("sv_enablebunnyhopping", "enable_bunnyhopping", "Let hopping build speed. Off applies CS's landing cap.")
	_movement_cvar("sv_airaccelerate", "air_accelerate", "Air acceleration. 1000 bhop, 150 surf, 10 CS.")
	_movement_cvar("sv_accelerate", "accelerate", "Ground acceleration.")
	_movement_cvar("sv_gravity", "gravity", "Gravity, u/s².")
	_movement_cvar("sv_friction", "friction", "Ground friction.")
	_movement_cvar("sv_stopspeed", "stop_speed", "Friction floor, u/s.")
	_movement_cvar("sv_maxspeed", "max_speed", "Run speed, u/s.")
	_movement_cvar("sv_maxvelocity", "max_velocity", "Velocity backstop, u/s.")
	_movement_cvar("sv_airwishcap", "air_wish_cap", "Airborne wish-speed cap, u/s. Hard-coded at 30 in those games.")
	_movement_cvar("sv_stepsize", "step_size", "Step height, units.")
	_movement_cvar("sv_edgefriction", "edge_friction", "Friction near a ledge. 1 disables.")
	_movement_cvar("sv_jumpbuffer", "jump_buffer", "Easy-bhop window in seconds when autobhop is off.")

	# The record's ghost, live. Turning it off takes the current one away rather than
	# waiting for the next map: an operator who turns a bot off wants it gone now.
	add_cvar("sv_replay_bot", "1" if game.config.show_replay_bot else "0",
		"Run the server record's replay as a visible bot.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.show_replay_bot = new_value != "0"
			if game.config.show_replay_bot:
				game.spawn_ghost()
			else:
				game.remove_player(G2GGame.GHOST_ID)
	)

	add_cvar("sv_allow_thirdperson", "1" if game.config.allow_thirdperson else "0",
		"Whether players may use third person.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.allow_thirdperson = new_value != "0"
			for id in game.players:
				var p: G2GPlayer = game.players[id]
				if p.camera != null:
					p.camera.allow_third_person = game.config.allow_thirdperson
					if not game.config.allow_thirdperson:
						p.camera.set_mode(G2GCamera.Mode.FIRST_PERSON)
	)

	# --- Commands ----------------------------------------------------------------
	add_command("g2g_status", _cmd_status, "What this server is doing", "").with_chat()
	add_command("g2g_restart", _cmd_restart, "Back to the start", "").with_chat()
	add_command("g2g_style", _cmd_style, "List styles, or switch", "").with_chat()
	add_command("g2g_track", _cmd_track, "main, or bonus <n>", "").with_chat()
	add_command("g2g_top", _cmd_top, "Fastest times here", "").with_chat()
	add_command("g2g_map", _cmd_map, "Change map, or list them", DotAdminFlags.CHANGEMAP)
	add_command("g2g_rtv", _cmd_rtv, "Rock the vote", "").with_chat()

	# What twenty years of bhop servers taught everybody's fingers: `!r`, `!wr`,
	# `!style`. Aliases of the commands above, chat-enabled, nothing else.
	add_command("r", _cmd_restart, "Back to the start (alias)", "").with_chat()
	add_command("wr", _cmd_top, "Fastest times here (alias)", "").with_chat()
	add_command("top", _cmd_top, "Fastest times here (alias)", "").with_chat()
	add_command("style", _cmd_style, "List styles, or switch (alias)", "").with_chat()
	add_command("track", _cmd_track, "main, or bonus <n> (alias)", "").with_chat()
	add_command("rtv", _cmd_rtv, "Rock the vote (alias)", "").with_chat()
	add_command("g2g_zone", _cmd_zone, "Draw a zone: g2g_zone <kind> [track] [number]", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_mark", _cmd_zone_mark, "Mark a corner where you stand", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_save", _cmd_zone_save, "Write the zones to disk", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_undo", _cmd_zone_undo, "Remove the last zone", DotAdminFlags.CHANGEMAP)
	add_command("g2g_zone_list", _cmd_zone_list, "List the zones", DotAdminFlags.CHANGEMAP)
	add_command("g2g_ghost", _cmd_ghost, "What the record ghost is running", "").with_chat()
	add_command("thirdperson", _cmd_thirdperson, "Third-person view", "").with_chat()
	add_command("firstperson", _cmd_firstperson, "First-person view", "").with_chat()

	server.client_disconnected.connect(_on_client_disconnected)
	hook_post("client_spawn", _on_client_spawn)
	hook_post("player_avatar_changed", _on_avatar_changed)
	add_command("g2g_net", func(ctx: DotCmdContext) -> void: ctx.reply_lines(net.describe_lines()), "Netcode state", "")
	_register_games()

	# What a server browser sees. Registered through the module so it goes away with
	# it; a provider left behind is called with `self` pointing at a freed object.
	var query := G2GQuery.new()
	query.game = game
	query.bridge = bridge
	var provided := add_query_provider(query)
	if not provided.ok:
		DotLog.info(CHANNEL, "no query provider", {"why": provided.error.message})

	log_info("g2gfast loaded", {"autobhop": game.config.auto_bhop, "tick_rate": game.tick_rate})
	return DotResult.success(null)


func _module_unload() -> void:
	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)
	if bridge != null and is_instance_valid(bridge):
		for userid in _joined.keys():
			bridge.remove_peer(bridge.peer_for_player(int(userid)))
	if game != null and is_instance_valid(game):
		for id in game.players.keys():
			game.remove_player(id)
		game.external_tick = false
	if net != null and is_instance_valid(net):
		net.stop()
	_painters.clear()
	_joined.clear()


## The manager and the bridge. The module drives the tick, because the game's tick
## has to happen INSIDE dot-net's — between applying inputs and building the snapshot.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	# A surf map is kilometres long in metres. The extent bounds position quantisation.
	config.world_extent = 512.0
	net.config = config
	add_child(net)

	var ready_result := net.setup()
	if not ready_result.ok:
		return ready_result.wrap("The netcode could not start")

	bridge = G2GNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net, server)
	if not attached.ok:
		return attached

	net.messages.seal()
	return net.start()


func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null:
		return
	_tick += 1
	bridge.server_tick(_tick)


## So `changegame` and a vote have something to change to. Ships in the build, so the
## client owns its own scene and the signon takes the no-scene path.
func _register_games() -> void:
	if server.games == null:
		return
	if server.games.find_game("g2gfast") != null:
		return
	var descriptor := DotGameDescriptor.new()
	descriptor.game_id = "g2gfast"
	descriptor.display_name = "g2gfast"
	descriptor.scene = "res://game/g2g.tscn"
	descriptor.client_scene = ""
	server.games.add_game(descriptor)


## A cvar mirrored onto a G2GConfig field. Writing it rebuilds every player's movement.
##
## Movement cvars are NOT startup-only: a surf server switches airaccelerate per map
## and that has to work live. What it costs is every run in progress, which
## `apply_movement` says loudly.
##
## [b]Validated BEFORE the config is written, through the console's own validator,
## and not after.[/b] The first version wrote the field, ran `validate()`, and on
## failure logged and returned — leaving the config invalid. `sv_maxvelocity 100`
## then blocked every later cvar: each one wrote its field, found the config still
## invalid because of the first, and quietly did nothing. The console reported all
## of them as set. Refusing at the console is what makes the operator see the
## refusal, and trying the value on a copy is what keeps the live config clean.
func _movement_cvar(cvar_name: String, field: String, description: String) -> void:
	var current: Variant = game.config.get(field)
	var text := ("1" if current else "0") if current is bool else str(current)

	var cvar := add_cvar(
		cvar_name, text, description, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	cvar.with_validator(func(proposed: String) -> DotResult:
		var trial := game.config.clone() as G2GConfig
		trial.set(field, _coerce(trial.get(field), proposed))
		return trial.validate()
	)

	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		game.config.set(field, _coerce(game.config.get(field), new_value))
		game.apply_movement()
	)


## A cvar's string in the type the config field already has.
static func _coerce(current: Variant, text: String) -> Variant:
	if current is bool:
		return text != "0" and text.to_lower() != "false" and text.to_lower() != "off"
	if current is int:
		return text.to_int()
	return text.to_float()


# --- Sessions --------------------------------------------------------------

## The event carries `userid`, not `peer_id` — dot-2d-hungry's note on this, in full:
## looking a session up by a peer id that is not in the payload returns null every
## time, and nobody is ever added, with no error.
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))
	if session == null or _joined.has(session.userid):
		return

	var added := bridge.add_player(
		session.peer_id, session.userid, session.display_name, _avatar_for(session)
	)
	if not added.ok:
		log_warn("could not add a player", {"userid": session.userid, "error": str(added.error)})
		return

	_joined[session.userid] = true


func _on_client_disconnected(session: DotClientSession, _reason: String = "") -> void:
	_painters.erase(_player_id(session))
	if _joined.has(session.userid):
		bridge.remove_peer(session.peer_id)
		_joined.erase(session.userid)


## The avatar dot-platform resolved for this session, if there is a dot-platform.
##
## Duck-typed: a module that answers `player_for` is enough, and naming
## DotPlatformModule would make a LAN server impossible without the identity stack.
## Without one, the game gives the player a stock character.
func _avatar_for(session: DotClientSession) -> DotAvatar:
	var platform: Object = server.modules.get_module("platform")
	if platform == null or not platform.has_method("player_for"):
		return null
	var player: Variant = platform.call("player_for", session)
	if player == null or not (player is Object):
		return null
	var avatar: Variant = (player as Object).get("avatar")
	return avatar as DotAvatar if avatar is DotAvatar else null


func _player_id(session: DotClientSession) -> StringName:
	return StringName("u%d" % session.userid)


func _caller_id(ctx: DotCmdContext) -> StringName:
	return _player_id(ctx.session) if ctx.session != null else &""


func _caller(ctx: DotCmdContext) -> G2GPlayer:
	var found: Variant = game.players.get(_caller_id(ctx))
	return found if found is G2GPlayer else null


# --- Commands --------------------------------------------------------------

func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(game.describe_lines())


func _cmd_restart(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can restart.")
		return
	game.spawn_player(id)
	ctx.reply("Back at the start.")


func _cmd_style(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Styles:"])
		for style in game.timers.styles_in_order():
			lines.append("  %-16s %-4s %s" % [String(style.id), style.short_name,
				"unranked" if not style.ranked else "x%.2f points" % style.points_multiplier])
		ctx.reply_lines(lines)
		return
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can switch style.")
		return
	if not game.set_player_style(id, StringName(ctx.args[0])):
		ctx.reply("No such style: %s" % ctx.args[0])
		return
	ctx.reply("Style: %s" % ctx.args[0])


func _cmd_track(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if not game.players.has(id):
		ctx.reply("Only a player can switch track.")
		return
	var track := DotTimerTrack.parse(" ".join(Array(ctx.args)))
	if track < 0:
		ctx.reply("No such track: %s" % " ".join(Array(ctx.args)))
		return
	game.timers.set_player_track(id, track)
	game.spawn_player(id)
	ctx.reply("Track: %s" % DotTimerTrack.name_of(track))


func _cmd_top(ctx: DotCmdContext) -> void:
	if game.maps.current == null or game.timers.store == null:
		ctx.reply("No records here.")
		return
	var timer := game.timers.timer_for(_caller_id(ctx))
	var track := timer.track if timer != null else DotTimerTrack.MAIN
	var style: StringName = timer.style.id if timer != null and timer.style != null else &"normal"
	var listed := game.timers.store.top(game.maps.current.id, track, style, 10)
	if not listed.ok:
		ctx.reply_error(listed)
		return
	var rows: Array = listed.value
	if rows.is_empty():
		ctx.reply("Nobody has finished %s on %s yet." % [String(game.maps.current.id), String(style)])
		return
	var lines := PackedStringArray()
	for i in range(rows.size()):
		var record: DotTimerRecord = rows[i]
		lines.append("  %2d. %-20s %s" % [i + 1, record.player_name, record.formatted_time()])
	ctx.reply_lines(lines)


func _cmd_map(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Maps:"])
		for map in game.maps.catalogue.maps:
			lines.append("  %-24s tier %d  %s" % [String(map.id), map.tier, String(map.kind)])
		ctx.reply_lines(lines)
		return
	var found := game.maps.catalogue.search(ctx.args[0])
	if found.size() != 1:
		ctx.reply("No map matches '%s'." % ctx.args[0] if found.is_empty() else "Which one?")
		return
	ctx.reply("Changing to %s." % found[0].name_or_id())
	var changed: DotResult = await game.change_map(found[0].id)
	if not changed.ok:
		ctx.reply_error(changed)


func _cmd_rtv(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)
	if id == &"":
		ctx.reply("Only a player can rock the vote.")
		return
	if game.rock_the_vote(id):
		ctx.reply("The vote passed.")
	else:
		ctx.reply("%d of %d." % [game.maps.time_limit.rtv_votes(),
			game.maps.time_limit.rtv_needed(game.players.size())])


func _painter_for(id: StringName) -> DotTimerZonePainter:
	if not _painters.has(id):
		_painters[id] = DotTimerZonePainter.on(game.timers.zones)
	var painter: DotTimerZonePainter = _painters[id]
	painter.zones = game.timers.zones
	# Zone heights in metres: 128 genre units of headroom, which is what the zone tools on those servers
	# gives and enough for a jumping player.
	painter.height = G2GUnits.to_metres(128.0)
	painter.padding = G2GUnits.to_metres(16.0)
	return painter


func _mark_position(ctx: DotCmdContext) -> Vector3:
	var player := _caller(ctx)
	if player != null:
		return player.controller.state.position
	var map := game.current_map_node()
	return map.spawn_for(DotTimerTrack.MAIN) if map != null else Vector3.ZERO


func _cmd_zone(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zone set.")
		return
	if ctx.args.is_empty():
		ctx.reply("g2g_zone <start|end|stage|respawn|stop|teleport> [track] [number]")
		return
	var kinds := {"start": DotTimerZone.Kind.START, "end": DotTimerZone.Kind.END,
		"stage": DotTimerZone.Kind.STAGE, "respawn": DotTimerZone.Kind.RESPAWN,
		"stop": DotTimerZone.Kind.STOP, "teleport": DotTimerZone.Kind.TELEPORT}
	var wanted := ctx.args[0].to_lower()
	if not kinds.has(wanted):
		ctx.reply("No such zone kind: %s" % ctx.args[0])
		return

	var track := DotTimerTrack.MAIN
	var consumed := 1
	if ctx.args.size() > 1:
		var text := ctx.args[1]
		if text.to_lower() in ["bonus", "b"] and ctx.args.size() > 2:
			text = "%s %s" % [text, ctx.args[2]]
			consumed = 2
		track = DotTimerTrack.parse(text)
		if track < 0:
			ctx.reply("No such track: %s" % text)
			return

	var number := 0.0
	if ctx.args.size() > consumed + 1 and ctx.args[consumed + 1].is_valid_float():
		number = ctx.args[consumed + 1].to_float()

	var began := _painter_for(_caller_id(ctx)).begin(kinds[wanted], track, number)
	if not began.ok:
		ctx.reply_error(began)
		return
	ctx.reply("Drawing a %s zone on %s. Stand on one corner and run g2g_zone_mark, then the other." % [
		wanted, DotTimerTrack.name_of(track)])


func _cmd_zone_mark(ctx: DotCmdContext) -> void:
	var painter := _painter_for(_caller_id(ctx))
	if painter.zones == null:
		ctx.reply("This map has no zone set.")
		return
	var marked := painter.mark(_mark_position(ctx))
	if not marked.ok:
		ctx.reply_error(marked)
		return
	if marked.value == null:
		ctx.reply("First corner. Now the other.")
		return
	game.timers.set_zones(painter.zones)
	ctx.reply("Drew %s." % str(marked.value))


func _cmd_zone_undo(ctx: DotCmdContext) -> void:
	var undone := _painter_for(_caller_id(ctx)).undo()
	if not undone.ok:
		ctx.reply_error(undone)
		return
	game.timers.set_zones(game.timers.zones)
	ctx.reply("Removed %s." % str(undone.value))


func _cmd_zone_list(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zones.")
		return
	ctx.reply_lines(_painter_for(_caller_id(ctx)).summary())


func _cmd_zone_save(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zones.")
		return
	var problems := game.timers.zones.problems()
	if not problems.is_empty():
		ctx.reply("Not saving — fix these first:")
		ctx.reply_lines(problems)
		return
	var path := ctx.args[0] if ctx.args.size() > 0 else "user://zones/%s.json" % String(game.timers.zones.map_id)
	var wrote := game.timers.zones.save_json(path)
	if not wrote.ok:
		ctx.reply_error(wrote)
		return
	ctx.reply("Wrote %s (%d zones)." % [path, game.timers.zones.zones.size()])


func _cmd_thirdperson(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or player.camera == null:
		ctx.reply("Only a player with a camera can do that.")
		return
	if not player.camera.set_mode(G2GCamera.Mode.THIRD_PERSON):
		ctx.reply("Third person is not allowed on this server.")
		return
	ctx.reply("Third person.")


func _cmd_firstperson(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)
	if player == null or player.camera == null:
		ctx.reply("Only a player with a camera can do that.")
		return
	player.camera.set_mode(G2GCamera.Mode.FIRST_PERSON)
	ctx.reply("First person.")


## dot-platform's broadcast_avatar_changes, received: the player is redressed and
## everybody is told, through the same JOIN a style change sends.
func _on_avatar_changed(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))
	if session == null or bridge == null:
		return
	var avatar := _avatar_for(session)
	if avatar != null:
		bridge.dress(session.userid, avatar)


func _cmd_ghost(ctx: DotCmdContext) -> void:
	if not game.config.show_replay_bot:
		ctx.reply("The replay bot is off (sv_replay_bot 0).")
		return

	var ghost := game.ghost()
	if ghost == null:
		ctx.reply("Nobody has set a record here yet, so there is nothing to run.")
		return

	ctx.reply("%s, %.0f%% through its run." % [
		ghost.display_name, ghost.replay.progress() * 100.0
	])
