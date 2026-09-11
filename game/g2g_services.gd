class_name G2GServices
extends Node

## Chat, voice and moderation on a dedicated timer server.
##
## The same shape as game-arena's `ArenaServices`, and deliberately a second copy
## rather than a shared file: nothing is shared between games in this family that is
## not an addon, and a helper living in one game and loaded by another would be a
## dependency neither declares. What differs is what a timer server wants, and it is
## not much — a radius channel is worth less on a course than in an arena, and a
## spectator channel is worth more.
##
## [b]dot-chat is the policy; dot-server stays the transport.[/b] Both would be two
## chat systems if both delivered a line, so exactly one does: the `player_chat` event
## is hooked and cancelled, the text goes to [DotChatRouter], and the router's
## `send_fn` hands each recipient's line back to dot-server's manager to put on the
## wire.
##
## [b]That is also what makes `!wr` and `!rtv` work the way this genre expects.[/b]
## dot-server's own chat has a command prefix and this game already registers its
## commands `.with_chat()`; what dot-chat adds is a prefix a game can claim, so a
## trigger that is not a console command — a poll, a nomination — is handled without
## being registered as one.
##
## [b]dot-moderation is here because dot-server's mute is two booleans on a session
## object, and a session dies with its connection.[/b] On a records server that matters
## more than usual: a gag is how an admin stops somebody spamming `!wr` at everybody,
## and one that lasts until they press reconnect is not a gag.

const CHANNEL := "g2g.services"

const CH_ALL := &"all"
const CH_TEAM := &"team"
const CH_WHISPER := &"whisper"

## Everybody who is mid-run. What a timer server's "spectators" channel is the inverse
## of, and the one audience rule that is about this genre rather than about chat.
const CH_RUNNING := &"running"

signal said(peer: int, message: DotChatMessage)
signal command_entered(peer: int, command: String, args: PackedStringArray)

@export_group("Moderation")

@export_file("*.json") var punishments_file: String = ""

@export var server_scope: String = ""

@export_group("Voice")

@export var voice_enabled: bool = true

## Metres a proximity packet carries.
##
## Larger than an arena's, because a course is long and thin: two players on the same
## ramp are further apart than two players in the same room, and a proximity range
## tuned for a room makes voice useless on a surf map.
@export_range(0.0, 500.0, 1.0) var voice_range: float = 120.0

var server: DotServer = null
var game: G2GGame = null
var link: Node = null

var chat: DotChatRouter = null
var voice: DotVoiceRouter = null
var moderation: DotModerationManager = null
## The website chat relay, when one is configured. See [method _build_relay].
var relay: DotChatRelay = null

## The relay's configuration. Left null, a default is built and the relay stays OFF.
##
## Off by default for the same reason every other power in this family is: a relay
## carries what your players type to a web page and back, and that is an operator's
## decision rather than a consequence of installing an addon.
@export var relay_config: DotChatRelayConfig = null

## The backbone client the relay posts through, assigned by the host BEFORE setup.
##
## [b]An [Object], not a [DotBackboneClient].[/b] The relay holds it duck-typed so that
## dot-chat need not depend on dot-auth, and keeping one spelling across the seam means
## the duck-typed contract is the only contract.
var backbone: Object = null


var _started: bool = false

## Latched by [method claim_command] for the duration of one command dispatch.
var _command_claimed: bool = false


func setup(p_server: DotServer, p_game: G2GGame, p_link: Node) -> DotResult:
	if _started:
		return DotResult.fail(DotError.CODE_STATE, "Already set up.")

	if p_server == null or p_game == null:
		return DotResult.fail(DotError.CODE_STATE, "Services need a server and a game.")

	server = p_server
	game = p_game
	link = p_link

	# Moderation FIRST. It publishes `dot_mute_source` on `_ready` and both routers
	# below look that name up when they start; a router that started first would find
	# nothing, warn once, and enforce no gag for the life of the server.
	var moderated: DotResult = await _build_moderation()

	if not moderated.ok:
		return moderated

	var chatted := _build_chat()

	if not chatted.ok:
		return chatted

	# After chat, because it needs the router; not fatal, because a relay that cannot
	# start is a server that still runs a perfectly good match.
	var relayed := _build_relay()
	DotLog.result(CHANNEL, "the website chat relay", relayed)

	if voice_enabled:
		_build_voice()

	_started = true
	return DotResult.success(self)


# --- Moderation ------------------------------------------------------------

func _build_moderation() -> DotResult:
	moderation = DotModerationManager.new()
	moderation.name = "Moderation"
	moderation.server_scope = server_scope
	moderation.register_mute_source = true
	moderation.register_ban_source = true

	if punishments_file != "":
		var store := DotPunishmentStoreFile.new()
		store.path = punishments_file
		moderation.store = store

	# A peer maps to a person by the SESSION id, never by the peer id: a peer id is
	# reassigned the moment somebody reconnects, and a ban keyed on one would be
	# served to the next player to join.
	moderation.key_for_peer = func(peer: int) -> String:
		var session := server.session_of(peer)
		return "" if session == null else DotPunishmentSubject.for_uid(str(session.userid))

	add_child(moderation)

	var loaded: DotResult = await moderation.load_all()

	if not loaded.ok:
		DotLog.warn(CHANNEL, "the punishment store could not be read", {
			"why": loaded.error.message
		})

	return DotResult.success(moderation)


# --- Chat ------------------------------------------------------------------

func _build_chat() -> DotResult:
	chat = DotChatRouter.new()
	chat.name = "Chat"
	chat.rules = _rules()
	chat.install_default_channels = false
	chat.handle_me_command = true

	chat.send_fn = _send
	chat.peers_fn = _playing_peers

	chat.name_fn = func(peer: int) -> String:
		var session := server.session_of(peer)
		return session.display_name if session != null else "unnamed"

	chat.key_fn = func(peer: int) -> String:
		var session := server.session_of(peer)
		return str(session.userid) if session != null else ""

	chat.position_fn = func(peer: int) -> Vector3:
		var player := _player_of(peer)
		return player.controller.state.position if player != null else Vector3.ZERO

	# [constant CH_RUNNING] is a MEMBERS channel, and this is what decides membership.
	# "Everybody who is mid-run" is a thing only this game knows, which is exactly why
	# dot-chat asks rather than deciding.
	chat.membership_fn = func(peer: int, channel_id: StringName) -> bool:
		if channel_id != CH_RUNNING:
			return true

		var player := _player_of(peer)
		return player != null and player.timer != null and player.timer.run.is_running()

	chat.is_admin_fn = func(peer: int) -> bool:
		var session := server.session_of(peer)
		return session != null and session.permissions.has(DotAdminFlags.CHAT)

	chat.gag_fn = func(peer: int) -> bool:
		var session := server.session_of(peer)
		return session != null and session.gagged

	add_child(chat)

	var started := chat.start()

	if not started.ok:
		return started.wrap("The g2gfast chat router could not start")

	for channel in _channels():
		var added := chat.add_channel(channel)

		if not added.ok:
			return added.wrap("A chat channel was refused")

	chat.message_accepted.connect(
		func(message: DotChatMessage, _to: PackedInt32Array) -> void:
			said.emit(message.sender_peer, message)
	)
	chat.command_entered.connect(
		func(peer: int, command: String, args: PackedStringArray, _raw: String) -> void:
			command_entered.emit(peer, command, args)
	)

	if server.events != null:
		server.events.hook_pre("player_chat", _on_player_chat)

		# **And `player_command`, without which this game's own chat commands do not
		# exist.** dot-server's chat manager checks for a command prefix BEFORE it fires
		# `player_chat`, and `_handle_command` returns on every path — including the
		# unknown-command one, which is silently ignored. Its prefixes are `["!", "/"]`,
		# identical to `DotChatRules`'.
		#
		# So a `!` line never reached [DotChatRouter] and `command_entered` could not
		# fire. `!rtv` survived only because `rtv` is also a console alias registered
		# with `.with_chat()`; **`!spec` and `!spectate` are handled nowhere else and
		# did nothing at all.**
		#
		# `player_command` fires before the console lookup and is cancellable, which is
		# the seam: the game gets first refusal, claims what it knows, and anything it
		# does not claim carries on to the console exactly as before.
		server.events.hook_pre("player_command", _on_player_command)

	return DotResult.success(chat)


func _channels() -> Array[DotChatChannel]:
	var out: Array[DotChatChannel] = []

	var everyone := DotChatChannel.everyone()
	everyone.id = CH_ALL
	out.append(everyone)

	var team := DotChatChannel.team()
	team.id = CH_TEAM
	out.append(team)

	# The one channel that is about this genre. A player mid-run does not want to read
	# about the map vote, and a player who is not running is the one who wants to talk.
	var running := DotChatChannel.make(
		CH_RUNNING, "Running", DotChatChannel.Scope.MEMBERS
	)
	running.prefix = "(run)"
	running.colour = Color(0.95, 0.85, 0.45)
	running.echo_to_sender = true
	out.append(running)

	var whisper := DotChatChannel.direct()
	whisper.id = CH_WHISPER
	out.append(whisper)

	return out


func _rules() -> DotChatRules:
	var rules := DotChatRules.new()

	rules.max_length = 220
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true

	rules.rate_per_minute = 25
	rules.burst = 4.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3

	# `!` and `/`, which is what twenty years of bhop servers taught everybody's
	# fingers — and what this game's own `.with_chat()` commands already answer to.
	rules.command_prefixes = PackedStringArray(["!", "/"])
	rules.broadcast_unknown_commands = false

	return rules


## dot-server's `player_chat`, intercepted and cancelled.
##
## The cancel reason is empty on purpose: the event's contract is that a cancelled
## message is refused and the player told why, and here the message is not refused at
## all — it is delivered by somebody else. A reason would put "Message blocked" in
## front of a player whose line went out perfectly.
func _on_player_chat(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	var text := event.get_string("text", "")
	var channel: StringName = CH_TEAM if event.get_bool("team_only", false) else CH_ALL

	# There are no teams on a timer server, so the team key means "the people I am
	# running with". Falling back is better than refusing: the player pressed a key
	# and something has to happen.
	if channel == CH_TEAM:
		channel = CH_RUNNING

	var submitted := chat.submit(session.peer_id, channel, text)

	if not submitted.ok:
		server.chat.send_system_to(session, submitted.error.message)

	event.cancel("")


func _send(wire: Dictionary, recipients: PackedInt32Array) -> void:
	if server.chat == null:
		return

	var message := DotChatMessage.from_dictionary(wire)

	if not message.ok:
		return

	var line := (message.value as DotChatMessage).describe()

	for peer in recipients:
		var session := server.session_of(peer)

		if session != null:
			server.chat.send_system_to(session, line)


func _playing_peers() -> PackedInt32Array:
	var out := PackedInt32Array()

	for session in server.playing_sessions():
		out.append(session.peer_id)

	return out


func claim_command() -> void:
	_command_claimed = true

	if chat != null:
		chat.claim_command()


## A `!command` from dot-server's chat manager, before it reaches the console.
func _on_player_command(event: DotEvent) -> void:
	var session := event.get_session()

	if session == null:
		return

	_command_claimed = false

	var raw_args: Array = event.data.get("args", [])
	var args := PackedStringArray()

	for arg in raw_args:
		args.append(str(arg))

	command_entered.emit(session.peer_id, event.get_string("command"), args)

	# Only what the game actually took. Everything else goes on to the console, which
	# is what keeps `!r`, `!wr`, `!top` and every dot-server command working.
	if _command_claimed:
		event.cancel("handled by the game", CHANNEL)


func announce(text: String) -> void:
	if chat != null:
		chat.announce(text, CH_ALL)


func notice(peer: int, text: String) -> void:
	if chat != null:
		chat.notice(peer, text, CH_ALL)



# --- The website relay -----------------------------------------------------

## Joins this server's chat to its room on the website.
##
## [b]Every seam points at something that already existed.[/b] The backbone client is
## dot-auth's. The permission answer is dot-server's admin manager, through
## `uid_has_permission` — the method written for exactly this, deciding what somebody may
## do when they are not connected. The command runner is `DotServer.run_command_as_uid`,
## which builds a context with that uid's OWN flags rather than RCON's root.
##
## Nothing here is a new policy. A relayed command is checked against the same file, by
## the same flags, as the same person typing it in game.
func _build_relay() -> DotResult:
	if relay_config == null:
		relay_config = DotChatRelayConfig.new()

	if not relay_config.enabled:
		return DotResult.success(null)

	if backbone == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The chat relay is on but no backbone client was handed to services."
		)

	relay = DotChatRelay.new()
	relay.name = "ChatRelay"
	relay.router = chat
	relay.config = relay_config
	relay.client = backbone
	relay.permission_fn = _uid_has_permission
	relay.command_fn = _run_relayed_command

	add_child(relay)

	var started := relay.start()

	if not started.ok:
		remove_child(relay)
		relay.queue_free()
		relay = null
		return started

	relay.site_command.connect(_on_site_command)

	return DotResult.success(relay)


func _uid_has_permission(uid: String, flag: String) -> bool:
	if server == null or server.admins == null:
		return false
	return server.admins.uid_has_permission(uid, flag)


func _run_relayed_command(
	uid: String, command: String, args: PackedStringArray, source: int
) -> void:
	if server == null:
		return

	for reply in server.run_command_as_uid(uid, command, args, source):
		DotLog.info(CHANNEL, "relayed command reply", {"uid": uid, "line": reply})


func _on_site_command(uid: String, command: String, allowed: bool) -> void:
	# Audited either way. A refusal is the half worth having a record of: it is somebody
	# trying to drive the server from a web page without the rights to.
	if server != null and server.audit != null:
		server.audit.record(
			"relay_command", "web:%s" % uid, command, {"allowed": allowed}
		)


# --- Voice -----------------------------------------------------------------

func _build_voice() -> void:
	voice = DotVoiceRouter.new()
	voice.name = "Voice"
	voice.config = DotVoiceConfig.new()
	# ALL rather than PROXIMITY, which is the opposite of an arena's default and is
	# the right answer here: a timer server is a room of people watching each other
	# run, and half of them are two hundred metres away down a course. Proximity is
	# available and an operator can pick it.
	voice.default_channel = DotVoiceRouter.Channel.ALL
	voice.proximity_range = voice_range
	voice.max_bytes_per_second = 6144

	voice.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		if link != null and link.has_method("send_voice"):
			link.call("send_voice", peer, bytes)

	voice.position_fn = func(peer: int) -> Vector3:
		var player := _player_of(peer)
		return player.controller.state.position if player != null else Vector3.ZERO

	add_child(voice)


func relay_voice(speaker_peer: int, bytes: PackedByteArray) -> void:
	if voice != null:
		voice.relay(speaker_peer, bytes)


# --- Sessions --------------------------------------------------------------

func add_peer(peer: int) -> void:
	if voice != null:
		voice.add_peer(peer)

	if chat == null:
		return

	var session := server.session_of(peer)

	if session != null:
		for row in chat.backlog_for(peer):
			var message := DotChatMessage.from_dictionary(row)

			if message.ok:
				server.chat.send_system_to(
					session, (message.value as DotChatMessage).describe()
				)

	chat.join_notice(peer, CH_ALL)


func remove_peer(peer: int) -> void:
	if chat != null:
		chat.leave_notice(peer, CH_ALL)
		chat.forget(peer)

	if voice != null:
		voice.remove_peer(peer)


func check_admission(session: DotClientSession) -> DotResult:
	if moderation == null or session == null:
		return DotResult.success(null)

	return moderation.check_admission(str(session.userid), session.address)


func _player_of(peer: int) -> G2GPlayer:
	var session := server.session_of(peer)

	if session == null:
		return null

	return game.players.get(StringName("u%d" % session.userid))


func describe() -> Dictionary:
	return {
		"chat": chat.describe() if chat != null else {},
		"voice": voice.describe() if voice != null else {},
		"moderation": moderation.describe() if moderation != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if chat != null:
		out.append_array(chat.describe_lines())

	if voice != null:
		out.append_array(voice.describe_lines())

	if moderation != null:
		out.append_array(moderation.describe_lines())

	return out
