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

## Chat, voice and moderation. See [G2GServices].
var services: G2GServices = null

## Content, profiles, avatars and admission. See [G2GIdentity].
var identity: G2GIdentity = null

## The ballot. What replaces the rock-the-vote this game shipped with.
var vote: G2GVote = null
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
	add_command("g2g_maps_reload", _cmd_maps_reload,
		"Re-read maps/ from disk, picking up anything dropped in", DotAdminFlags.CHANGEMAP)
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

	# --- Mode cvars, live -------------------------------------------------------
	#
	# Each one flips a layer that is already built. A layer constructed on the cvar
	# instead would be constructed under live players, which is where the interesting
	# failures are — and it would have to be torn down again on the way back.
	add_cvar("sv_deathmatch", "1" if game.config.deathmatch else "0",
		"Whether players can shoot each other.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.deathmatch = new_value != "0"

			if game.combat != null:
				game.combat.enabled = game.config.deathmatch
			elif game.config.deathmatch:
				log_warn("deathmatch cannot be turned on", {
					"why": "this server booted without it; restart with sv_deathmatch 1"
				})
	)

	add_cvar("sv_hunters", "1" if game.config.hunters else "0",
		"Whether hunters walk the course.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.hunters = new_value != "0"

			if game.hunters == null:
				return

			game.hunters.enabled = game.config.hunters

			# Off takes them away now rather than waiting for the next map — the same
			# rule `sv_replay_bot` follows, and for the same reason: an operator who
			# turns something off wants it gone.
			if not game.config.hunters:
				game.hunters.clear()
	)

	add_cvar("sv_props", "1" if game.config.placeable_props else "0",
		"Whether practice blocks may be placed.").changed.connect(
		func(_old: String, new_value: String) -> void:
			game.config.placeable_props = new_value != "0"

			if game.props != null and not game.config.placeable_props:
				game.props.clear()
	)

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

	# Everything below runs the server rather than the game, and each one logs and
	# continues rather than refusing to load: a module that would not load because a
	# punishment file was unreadable is a module that takes the game down over a
	# permissions mistake, and the game is what the players came for.
	var identified: DotResult = await _build_identity()
	DotLog.result(CHANNEL, "the identity layer", identified)

	var serviced: DotResult = await _build_services()
	DotLog.result(CHANNEL, "chat, voice and moderation", serviced)

	var voted := _build_vote()
	DotLog.result(CHANNEL, "the vote", voted)

	_add_server_commands()

	log_info("g2gfast loaded", {"autobhop": game.config.auto_bhop, "tick_rate": game.tick_rate})
	return DotResult.success(null)


## dot-platform's own module, loaded beside this one.
##
## A PATH, because `DotModuleHost.load_module` takes one and constructs the module
## itself — so a pre-built instance with its hub assigned would be thrown away and a
## fresh one made with a null. dot-platform's module falls back to
## `DotRegistry.get_service(DotPlatformHub.SERVICE)` for exactly this, which is why
## [G2GIdentity] registers the hub.
const PLATFORM_MODULE_PATH := "res://addons/dot_platform/dot_platform_module.gd"


func _build_identity() -> DotResult:
	identity = G2GIdentity.new()
	identity.name = "Identity"
	identity.report_to_backbone = game.config.report_to_backbone
	add_child(identity)

	var ready: DotResult = await identity.setup()

	if not ready.ok:
		remove_child(identity)
		identity.queue_free()
		identity = null
		return ready

	if server.modules != null and not server.modules.has_module("platform"):
		var loaded := server.modules.load_module(PLATFORM_MODULE_PATH)

		if not loaded.ok:
			return loaded.wrap("The platform module would not load")

	return DotResult.success(identity)


func _build_services() -> DotResult:
	services = G2GServices.new()
	services.name = "Services"
	add_child(services)

	var ready: DotResult = await services.setup(server, game, bridge.link)

	if not ready.ok:
		remove_child(services)
		services.queue_free()
		services = null
		return ready

	if services.voice != null and bridge != null:
		bridge.voice_relay_fn = services.relay_voice

	services.command_entered.connect(_on_chat_command)

	return DotResult.success(services)


func _build_vote() -> DotResult:
	vote = G2GVote.new()
	vote.name = "Vote"
	vote.game = game
	vote.authoritative = true
	add_child(vote)

	vote.announce_fn = func(line: String) -> void:
		if services != null:
			services.announce(line)
		else:
			server.broadcast_message(line)

	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(G2GCombat.entity_id_for(voter))
		return session != null and session.permissions.has(DotAdminFlags.CHANGEMAP)

	var ready := vote.setup()

	if not ready.ok:
		remove_child(vote)
		vote.queue_free()
		vote = null
		return ready

	return DotResult.success(vote)


## The commands that only exist once the optional halves loaded.
func _add_server_commands() -> void:
	if vote != null:
		add_command("nominate", _cmd_nominate,
			"Nominate a map: !nominate <id>", "").with_chat()
		add_command("nextmap", _cmd_nextmap, "What plays next", "").with_chat()
		add_command("timeleft", _cmd_timeleft, "How long this map has", "").with_chat()
		add_command("g2g_vote", _cmd_open_vote, "Open a vote now", DotAdminFlags.VOTE)

	if services != null:
		add_command("g2g_services", _cmd_services,
			"Chat, voice and moderation", DotAdminFlags.GENERIC)

	if identity != null:
		add_command("g2g_identity", _cmd_identity,
			"The platform layer", DotAdminFlags.GENERIC)

	if game.progress != null:
		add_command("stats", _cmd_stats, "Your numbers on this server", "").with_chat()

	if game.hunters != null:
		add_command("g2g_hunt", _cmd_hunt,
			"Show, clear, or place one: g2g_hunt [clear|spawn <id>]",
			DotAdminFlags.GENERIC)

	if game.props != null:
		add_command("g2g_place", _cmd_place,
			"Place a block where you are looking", DotAdminFlags.CHANGEMAP)
		add_command("g2g_place_undo", _cmd_place_undo,
			"Take the last block back", DotAdminFlags.CHANGEMAP)
		add_command("g2g_place_clear", _cmd_place_clear,
			"Clear every placed block", DotAdminFlags.CHANGEMAP)
		add_command("g2g_nudge", _cmd_nudge,
			"Grab the block you are looking at, or drop the one you hold",
			DotAdminFlags.CHANGEMAP)


func _cmd_nominate(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		ctx.reply("Usage: !nominate <map>")
		return

	var res := vote.nominate(_caller_id(ctx), StringName(ctx.args[0]))
	ctx.reply("Nominated." if res.ok else res.error.message)


func _cmd_nextmap(ctx: DotCmdContext) -> void:
	ctx.reply("Next: %s" % vote.next_map())


func _cmd_timeleft(ctx: DotCmdContext) -> void:
	ctx.reply(vote.timeleft_line())


func _cmd_open_vote(ctx: DotCmdContext) -> void:
	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	ctx.reply("Vote opened." if opened.ok else opened.error.message)


func _cmd_services(ctx: DotCmdContext) -> void:
	ctx.reply_lines(services.describe_lines())


func _cmd_identity(ctx: DotCmdContext) -> void:
	ctx.reply_lines(identity.describe_lines())


func _cmd_stats(ctx: DotCmdContext) -> void:
	var id := _caller_id(ctx)

	if id == &"":
		ctx.reply("Only a player has numbers.")
		return

	var values := game.progress.session_values(id)

	ctx.reply("Runs: %d started, %d finished" % [
		int(values.get_value(G2GStats.RUNS_STARTED, 0.0)),
		int(values.get_value(G2GStats.RUNS_FINISHED, 0.0)),
	])
	ctx.reply("Jumps: %d, %.0f%% perfect" % [
		int(values.get_value(G2GStats.JUMPS, 0.0)),
		G2GStats.perfect_ratio_of(values) * 100.0,
	])
	# Both derived, never stored: a stored quotient is a third number that can
	# disagree with the two it came from.
	ctx.reply("Finish rate: %.0f%%" % [G2GStats.finish_rate_of(values) * 100.0])
	ctx.reply("Top speed: %.0f u/s over %.0f m" % [
		values.get_value(G2GStats.TOP_SPEED, 0.0),
		values.get_value(G2GStats.DISTANCE, 0.0),
	])
	ctx.reply("Achievement points: %d" % game.progress.points_of(id))


func _cmd_hunt(ctx: DotCmdContext) -> void:
	if not ctx.args.is_empty() and ctx.args[0] == "clear":
		ctx.reply("Removed %d hunter(s)." % game.hunters.clear())
		return

	if not ctx.args.is_empty() and ctx.args[0] == "spawn":
		var caller := _caller(ctx)

		if caller == null:
			ctx.reply("Stand somewhere first.")
			return

		var which: StringName = (
			StringName(ctx.args[1]) if ctx.args.size() > 1 else G2GHunters.STALKER
		)

		# In front of the admin rather than at their feet, so the thing they just
		# placed is not immediately inside them.
		var at := caller.eye_position() + caller.aim_direction() * 4.0
		var made := game.hunters.spawn_one(which, at)

		ctx.reply(
			"Placed a %s." % String(which) if made != null
			else "That hunter could not be placed."
		)
		return

	ctx.reply_lines(game.hunters.describe_lines())


func _cmd_place(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Stand somewhere first.")
		return

	var which: StringName = (
		StringName(ctx.args[0]) if not ctx.args.is_empty() else G2GProps.BLOCK
	)

	# Where they are looking, four metres out. The same "mark where you stand" idea
	# `g2g_zone_mark` uses, one step in front so the block is not inside the admin.
	var at := player.eye_position() + player.aim_direction() * 4.0
	var made := game.props.place(_caller_id(ctx), which, at, true)

	ctx.reply(
		"Placed %s." % String(which) if made != null
		else "That block could not be placed."
	)


func _cmd_place_undo(ctx: DotCmdContext) -> void:
	ctx.reply("Removed." if game.props.undo(_caller_id(ctx)) else "Nothing to remove.")


func _cmd_place_clear(ctx: DotCmdContext) -> void:
	ctx.reply("Cleared %d block(s)." % game.props.clear())


## Grabs, or drops. One command for both, because an admin who has to remember which
## of two they typed last is an admin holding a block they cannot put down.
func _cmd_nudge(ctx: DotCmdContext) -> void:
	var caller := _caller(ctx)

	if caller == null:
		ctx.reply("Stand somewhere first.")
		return

	var id := _caller_id(ctx)

	if game.props.drop(id):
		ctx.reply("Dropped it, frozen where it is.")
		return

	var took := game.props.nudge(
		id, caller.eye_position(), caller.aim_direction(),
		1.0 / float(maxi(game.tick_rate, 1))
	)

	ctx.reply("Grabbed it — it follows you now." if took else "Nothing there.")


## A player typed `!something` that dot-server's own commands did not answer.
##
## [b]Claimed, or it is broadcast as chat.[/b] dot-chat holds a command until somebody
## says they handled it; an unclaimed one with `broadcast_unknown_commands` off is
## dropped, so a player typing `!rtv` on a server whose vote failed to load would get
## silence rather than "there is no vote here".
func _on_chat_command(peer: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer)

	if session == null:
		return

	var voter := _player_id(session)

	match command:
		"rtv":
			if vote == null:
				services.notice(peer, "There is no vote on this server.")
			else:
				var res := vote.rock_the_vote(voter)
				services.notice(peer, "Rocked the vote." if res.ok else res.error.message)

			services.claim_command()
		"spec", "spectate":
			if game.spectate == null:
				services.notice(peer, "Spectating is not available here.")
			elif args.is_empty():
				var best := game.spectate.watch_best(voter)
				services.notice(
					peer,
					("Watching %s. !spec off to stop."
						% game.spectate.target_of(voter)) if best.ok
					else best.error.message
				)
			elif args[0] == "off" or args[0] == "stop":
				game.spectate.stop(voter)
				services.notice(peer, "Back to your own view.")
			else:
				# By name, and then by id. A player types what is on the scoreboard and
				# an id is what the game keys by; asking for the id alone is asking a
				# player to know something they cannot see.
				var wanted := _player_named(args[0])
				var res := game.spectate.watch(
					voter, wanted if wanted != &"" else StringName(args[0])
				)
				services.notice(
					peer,
					("Watching %s." % game.spectate.target_of(voter)) if res.ok
					else res.error.message
				)

			services.claim_command()
		"specnext", "next":
			if game.spectate == null:
				services.notice(peer, "Spectating is not available here.")
			else:
				var res := game.spectate.next_target(voter)
				services.notice(
					peer,
					("Watching %s." % game.spectate.target_of(voter)) if res.ok
					else res.error.message
				)

			services.claim_command()
		"vote":
			if args.is_empty():
				services.notice(peer, "Usage: !vote <map>")
			elif vote == null or not vote.is_voting():
				services.notice(peer, "No vote is open.")
			else:
				var res := vote.cast_one(voter, StringName(args[0]))
				services.notice(peer, "Counted." if res.ok else res.error.message)

			services.claim_command()
		_:
			# Left for dot-server's own chat commands, which this game registers with
			# `.with_chat()` — `!r`, `!wr`, `!top`, `!style`, `!track`.
			pass


## A player id by display name, or "".
##
## Case-insensitive and by prefix, which is what every server in this genre does —
## `!spec ad` finds Ada. The first match wins and the order is the roster's, which is
## stable; the alternative is refusing an ambiguous prefix, and a player who typed two
## letters and got "be more specific" types three letters and gives up.
func _player_named(text: String) -> StringName:
	var wanted := text.strip_edges().to_lower()

	if wanted == "":
		return &""

	for session in server.sessions():
		var name := session.display_name.to_lower()
		if name == wanted or name.begins_with(wanted):
			return _player_id(session)

	return &""


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


func _physics_process(delta: float) -> void:
	if not loaded or bridge == null:
		return
	_tick += 1
	bridge.server_tick(_tick)

	# The vote clock, from the SIMULATED tick rather than from the frame. dot-vote
	# says why and it is the same reason dot-map does: a server that stalls should not
	# lose that time off its map, and a test must be able to run an hour of one in a
	# millisecond.
	if vote != null:
		vote.advance(delta)


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

	# dot-moderation's records, which are not dot-server's ban list.
	#
	# [b]dot-server's mute is two booleans on a session object and a session dies with
	# its connection[/b], so a muted player reconnects and talks. A punishment is a
	# durable record with an expiry and a scope, and this is the second gate — the
	# first is dot-server's own admission, which has already run.
	if services != null:
		var admitted := services.check_admission(session)

		if not admitted.ok:
			server.kick(session, admitted.error.message)
			return

	var added := bridge.add_player(
		session.peer_id, session.userid, session.display_name, _avatar_for(session)
	)
	if not added.ok:
		log_warn("could not add a player", {"userid": session.userid, "error": str(added.error)})
		return

	_joined[session.userid] = true

	if services != null:
		services.add_peer(session.peer_id)


func _on_client_disconnected(session: DotClientSession, _reason: String = "") -> void:
	_painters.erase(_player_id(session))

	if services != null:
		services.remove_peer(session.peer_id)

	if vote != null:
		# Their rock-the-vote and their nominations. `rtv_forgets_leavers` decides
		# whether the tally shrinks with them, and it cannot do its job if nothing
		# tells it they went.
		vote.forget_voter(_player_id(session))

	if game != null and game.props != null:
		game.props.release_player(_player_id(session))

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
		return _identity_avatar(session)
	var player: Variant = platform.call("player_for", session)
	if player == null or not (player is Object):
		return _identity_avatar(session)
	var avatar: Variant = (player as Object).get("avatar")
	if avatar is DotAvatar:
		return avatar as DotAvatar
	return _identity_avatar(session)


## The hub's own answer, when the module has not resolved one yet.
##
## [b]Admission finishes AFTER a client is spawned, and this is the gap that leaves.[/b]
## dot-platform's module runs off `client_state_changed` because dot-server has no
## cancellable stage between authentication and content — its own notes say so — so a
## player can be in the world with the platform still resolving them. Asking the hub
## directly closes it: the hub answers with what it has, and `G2GIdentity.avatar_for`
## falls back to the stock document, which is a real avatar over the same schema.
func _identity_avatar(session: DotClientSession) -> DotAvatar:
	if identity == null or session == null:
		return null

	return identity.avatar_for("u%d" % session.userid)


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


## Re-read the map directory on a running server.
##
## What makes an imported map worth having is that an operator can drop one in; a
## server that reads the disk once at boot makes them restart to play it, which on a
## live server means kicking everybody in order to add a map.
func _cmd_maps_reload(ctx: DotCmdContext) -> void:
	var change := game.rescan_maps()
	var added: Array = change["added"]
	var removed: Array = change["removed"]
	var lines := PackedStringArray([
		"%d maps (%d added, %d removed)" % [change["total"], added.size(), removed.size()]
	])
	for id: StringName in added:
		lines.append("  + %s" % String(id))
	for id: StringName in removed:
		lines.append("  - %s" % String(id))
	# Naming the map still being played is the one thing an operator needs told: it
	# keeps running, deliberately, and will not be chosen again.
	if game.maps.current != null and not game.maps.catalogue.has(game.maps.current.id):
		lines.append("  %s is still being played and is no longer on disk"
			% String(game.maps.current.id))
	ctx.reply_lines(lines)


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
