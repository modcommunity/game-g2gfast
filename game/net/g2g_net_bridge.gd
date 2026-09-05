class_name G2GNetBridge
extends Node

## Joins a [G2GGame] to a [DotNetManager]. The netcode seam, and the only file in
## this project that names both.
##
## [b]The ordering is the whole file.[/b] dot-net drives simulation per entity, and
## this game's tick is a whole-game property: everybody moves, then every timer is fed
## the position its move produced. [method ensure_game_ticked] reconciles the two —
## the first behaviour through on a tick runs the whole game, the rest find it done.
##
## [codeblock]
## # server
## bridge.attach(game, net, server)      # `server` is the node the link mirrors
## bridge.add_player(peer_id, session_id, "Ada", avatar)
## bridge.server_tick(tick)              # instead of the game's own loop
##
## # client
## bridge.attach(game, net, client_link)
## bridge.ask_ready()
## bridge.client_tick(tick, command)
## [/codeblock]
##
## Modelled on dot-2d-hungry's bridge, the one in this family proven over a real
## socket, with two things it does not need — chunked field state and per-piece
## entities — left out, and one it lacks: the movement configuration travels, so a
## client derives bit-identical tunables and prediction converges.

const CHANNEL := "g2g.net"
const ACK_BYTES := 4

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)
signal roster_changed(player_id: int)
## A finish announced by the authority. [param rank] 0 means it was not filed.
signal finish_received(player_id: int, time: float, rank: int)
signal notice_received(player_id: int, text: String)

var game: G2GGame = null
var net: DotNetManager = null
var link: G2GNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns how long the link is, in milliseconds. dot-net never
## touches a transport and cannot measure it; dot-server's heartbeat already does
## (`DotClientLink.ping_ms()`), and a client that feeds nothing has a clock that
## assumes an instant connection and stamps every command for a tick the server has
## already simulated. Read on every snapshot.
var rtt_source: Callable = Callable()


var _entities: Node = null
var _behaviours: Dictionary = {}
var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
var _tick: int = 0
var _adding: bool = false
var _game_ticked_for: int = -1
var _client_ticked_for: int = -1

## A style index -> id table both ends build identically. See [DotTimerNet].
var _style_ids: Array[StringName] = []


# --- Wiring ----------------------------------------------------------------

func attach(p_game: G2GGame, p_net: DotNetManager, link_parent: Node) -> DotResult:
	if p_game == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_game.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game=%s net.is_server=%s" % [p_game.authoritative, p_net.is_server]
		)

	game = p_game
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	for style in game.timers.styles_in_order():
		_style_ids.append(style.id)

	net.send_fn = _send

	var event := net.messages.register(
		G2GEvent.NAME, G2GEvent, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)
	if not event.ok:
		return event
	var request := net.messages.register(
		G2GRequest.NAME, G2GRequest, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)
	if not request.ok:
		return request

	net.messages.on(G2GEvent.NAME, _on_event)
	net.messages.on(G2GRequest.NAME, _on_request)

	link = G2GNetLink.attached_to(link_parent, self, net.is_server)

	# Both ends: the server's tick is server_tick, and the client's is client_tick,
	# which simulates what it predicts and leaves the rest to interpolation. A
	# client game still running its own loop would simulate the local player twice
	# a tick and dead-reckon every remote one from stale state.
	game.external_tick = true

	if net.is_server:
		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.timers.player_started.connect(_on_run_started)
		game.timers.player_stopped.connect(_on_run_stopped)
		game.timers.player_staged.connect(_on_staged)
		game.run_filed.connect(_on_run_filed)
		game.movement_changed.connect(_on_movement_changed)
		game.map_ready.connect(_on_map_ready)

	return DotResult.success(self)


func _style_index(id: StringName) -> int:
	return maxi(_style_ids.find(id), 0)


func _style_id(index: int) -> StringName:
	return _style_ids[index] if index >= 0 and index < _style_ids.size() else &"normal"


# --- Transport -------------------------------------------------------------

func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return
	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


## Peer by peer, never the broadcast address: a broadcast reaches peers that have
## not built their scene yet, and every one of those is a lost event.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server:
		return
	for peer_id in _ready_peers.keys():
		net.send(G2GEvent.of(kind, body), int(peer_id))


func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net != null and net.is_server and peer_id > 0:
		net.send(G2GEvent.of(kind, body), peer_id)


# --- Membership (server) ---------------------------------------------------

## Adds a player and makes them a replicated entity. [param session_id] is the id
## everything is keyed by; a peer id is reassigned on reconnect.
func add_player(
	peer_id: int, session_id: int, display_name: String, avatar: DotAvatar = null
) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var id := _player_key(session_id)
	_adding = true
	var player := game.add_player(id, display_name, false, avatar)
	_adding = false

	if player == null:
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	var identity := _build_entity(player, peer_id)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		game.remove_player(id)
		return registered

	if peer_id > 0:
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)

	return DotResult.success(player)


func remove_peer(peer_id: int) -> void:
	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)
	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)

	# Released BEFORE the game is told, and the ordering is load-bearing:
	# game.remove_player emits player_removed, which _on_player_removed answers by
	# releasing the entity and broadcasting LEAVE. Releasing first empties
	# _behaviours, so that handler finds nothing and this function stays the one
	# place a leaving player is announced.
	_release_entity(session_id)
	game.remove_player(_player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)
		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(G2GEvents.Kind.LEAVE, G2GEvents.write_player(session_id))
	roster_changed.emit(session_id)


## A player the game made itself — its ghost — becomes a bot: an entity with no
## peer, replicated to everybody, as a bot on any server is.
func _on_player_added(player: G2GPlayer) -> void:
	if _adding or player == null or net == null or not net.is_server:
		return
	var session_id := session_of(player.player_id)
	if _behaviours.has(session_id):
		return
	var identity := _build_entity(player, 0)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a game-made player", {"error": str(registered.error)})
		return
	_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)
	if _behaviours.has(session_id):
		# The game removed it itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(G2GEvents.Kind.LEAVE, G2GEvents.write_player(session_id))
		roster_changed.emit(session_id)


static func _player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func _build_entity(player: G2GPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: DotNetIdentity collects behaviours
	# in _ready by walking the subtree, and one added afterwards would never be found.
	var behaviour := G2GPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's
	# own movement a round trip behind their keys.
	identity.authority = DotNetIdentity.Authority.SHARED
	identity.always_relevant = true
	player.add_child(identity)

	_behaviours[session_of(player.player_id)] = behaviour
	return identity


func _release_entity(session_id: int) -> void:
	var behaviour: G2GPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)
	if behaviour != null and behaviour.identity != null and net != null:
		net.registry.unregister(behaviour.identity.net_id)


## Redresses a player from the server side — dot-platform's wardrobe change — and
## tells everybody. The same path a client's own AVATAR request takes.
func dress(session_id: int, avatar: DotAvatar) -> bool:
	var player: G2GPlayer = game.players.get(_player_key(session_id)) if game != null else null
	if player == null or avatar == null:
		return false
	if not player.rig.dress(avatar, game.avatar_schema, game.avatar_catalogue).ok:
		return false
	_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
	return true


func behaviour_for(session_id: int) -> G2GPlayerNet:
	return _behaviours.get(session_id)


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


func local_player() -> G2GPlayer:
	return game.players.get(_player_key(local_player_id)) if game != null else null


# --- The authoritative tick ------------------------------------------------

## One server tick, replacing the game's own loop.
func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1
	if net != null:
		net.server_tick(tick)
	ensure_game_ticked(tick)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return
	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: G2GPlayerNet = _behaviours[session_id]
		# Only what a peer sent. A bot has no peer and is driven by something else
		# — a replay, a test, an AI — and an empty command applied over the top of
		# that would stand it still.
		if behaviour.player != null and behaviour.identity != null and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())

	game.tick_once(tick)


# --- The client tick -------------------------------------------------------

func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := G2GNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from last_move, on a fresh tick and on a replayed one
	# alike — the predictor's replay sets it through _net_apply_input, and this is
	# the fresh tick's equivalent.
	var mine: G2GPlayerNet = _behaviours.get(local_player_id)
	if mine != null:
		mine.last_move = packet.move

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		packet.write(writer)
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# The whole client game ticks once: predicted players simulate through their
	# behaviours, and every timer — including remote players' — is fed afterwards.
	if _client_ticked_for != tick:
		_client_ticked_for = tick
		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())
		game.tick_timers_only(tick)


# --- Receiving -------------------------------------------------------------

func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))
	return net.receive_snapshot(payload)


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")
	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")
	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	var packet := G2GNetCommand.new()
	packet.read(DotNetReader.new(payload.slice(ACK_BYTES)))
	return net.input_buffer_for(peer_id).push(packet)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, peer_id)


# --- Server: what a joining peer is told ------------------------------------

func _admit(peer_id: int) -> void:
	if peer_id <= 0 or not _player_of_peer.has(peer_id):
		return

	_ready_peers[peer_id] = true
	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, G2GEvents.Kind.HELLO, G2GEvents.write_hello(
		game.tick_rate, session_id, peer_id, net.clock.tick,
		game.maps.current.id if game.maps.current != null else &"", game.config
	))

	for other in _behaviours.keys():
		_tell(peer_id, G2GEvents.Kind.JOIN, _join_body(int(other)))

	for other in _behaviours.keys():
		_send_timer(int(other), peer_id)


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: G2GPlayerNet = _behaviours.get(session_id)
	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	var player := behaviour.player
	return G2GEvents.write_join(
		session_id, peer_for_player(session_id), behaviour.identity.net_id,
		player.display_name, player.rig.avatar,
		_style_index(player.timer_style.id if player.timer_style != null else &"normal"),
		player.timer.track if player.timer != null else 0
	)


func _send_timer(session_id: int, to_peer: int = 0) -> void:
	var player: G2GPlayer = game.players.get(_player_key(session_id))
	if player == null or player.timer == null:
		return

	var state := DotTimerNet.state_of(
		player.timer.run, _tick,
		_style_index(player.timer.style.id if player.timer.style != null else &"normal")
	)
	var body := G2GEvents.write_timer(session_id, state)

	if to_peer > 0:
		_tell(to_peer, G2GEvents.Kind.TIMER, body)
	else:
		_broadcast(G2GEvents.Kind.TIMER, body)


func _on_run_started(id: StringName, _run: DotTimerRun) -> void:
	_send_timer(session_of(id))


func _on_run_stopped(id: StringName, _run: DotTimerRun, _reason: StringName) -> void:
	_send_timer(session_of(id))


func _on_staged(id: StringName, number: int, split: float) -> void:
	var session_id := session_of(id)
	_tell(peer_for_player(session_id), G2GEvents.Kind.NOTICE, G2GEvents.write_text(
		session_id, "Stage %d — %s" % [number, DotTimerRun.format_time(split)]
	))


func _on_run_filed(id: StringName, run: DotTimerRun, rank: int, reason: String) -> void:
	var session_id := session_of(id)
	var player: G2GPlayer = game.players.get(id)
	if player == null or run == null:
		return

	var finish := DotTimerNet.finish_of(run, _style_index(run.style_id), rank)
	_broadcast(G2GEvents.Kind.FINISH, G2GEvents.write_finish(session_id, finish))

	if reason != "":
		_tell(peer_for_player(session_id), G2GEvents.Kind.NOTICE,
			G2GEvents.write_text(session_id, "Not recorded: %s" % reason))
	elif rank == 1:
		_broadcast(G2GEvents.Kind.RECORD, G2GEvents.write_text(
			session_id, "%s set a server record: %s" % [player.display_name, run.formatted_time()]
		))


func _on_movement_changed(config: G2GConfig) -> void:
	_broadcast(G2GEvents.Kind.MOVEMENT, G2GEvents.write_movement(config))


func _on_map_ready(map: DotMapDef) -> void:
	_broadcast(G2GEvents.Kind.MAP, G2GEvents.write_map(map.id))
	for session_id in _behaviours.keys():
		_broadcast(G2GEvents.Kind.JOIN, _join_body(int(session_id)))


# --- Client: asking ----------------------------------------------------------

func ask_ready() -> void:
	_ask(G2GEvents.Ask.READY, PackedByteArray())


func ask_style(style_id: StringName) -> void:
	_ask(G2GEvents.Ask.STYLE, G2GEvents.write_int(_style_index(style_id)))


func ask_track(track: int) -> void:
	_ask(G2GEvents.Ask.TRACK, G2GEvents.write_int(track))


func ask_restart() -> void:
	_ask(G2GEvents.Ask.RESTART, PackedByteArray())


func ask_rtv() -> void:
	_ask(G2GEvents.Ask.RTV, PackedByteArray())


func ask_checkpoint(action: int) -> void:
	_ask(G2GEvents.Ask.CHECKPOINT, G2GEvents.write_int(action))


func publish_avatar(avatar: DotAvatar) -> void:
	_ask(G2GEvents.Ask.AVATAR, G2GEvents.write_avatar(avatar))


func _ask(kind: int, body: PackedByteArray) -> void:
	if net != null and not net.is_server:
		net.send(G2GRequest.of(kind, body), 1)


# --- Server: answering ------------------------------------------------------

func _on_request(message: DotNetMessage) -> void:
	var ask := message as G2GRequest
	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id
	var session_id := player_for_peer(peer_id)
	if session_id == 0:
		return

	var id := _player_key(session_id)
	var reader := ask.reader()

	match ask.kind:
		G2GEvents.Ask.READY:
			_admit(peer_id)
		G2GEvents.Ask.STYLE:
			if game.set_player_style(id, _style_id(G2GEvents.read_int(reader))):
				_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
		G2GEvents.Ask.TRACK:
			var track := G2GEvents.read_int(reader)
			if DotTimerTrack.is_valid(track) and game.timers.set_player_track(id, track):
				game.spawn_player(id)
				_broadcast(G2GEvents.Kind.JOIN, _join_body(session_id))
		G2GEvents.Ask.AVATAR:
			var avatar := G2GEvents.read_avatar(reader)
			var player: G2GPlayer = game.players.get(id)
			# Conformed by the rig's own dress path: a part this build lacks is
			# dropped, and a document that fails outright leaves the stock one.
			if avatar != null and player != null:
				dress(session_id, avatar)
		G2GEvents.Ask.RESTART:
			game.spawn_player(id)
		G2GEvents.Ask.RTV:
			game.rock_the_vote(id)
		G2GEvents.Ask.CHECKPOINT:
			_checkpoint(id, G2GEvents.read_int(reader))


func _checkpoint(id: StringName, action: int) -> void:
	var player: G2GPlayer = game.players.get(id)
	var checkpoints := game.timers.checkpoints_for(id)
	if player == null or checkpoints == null:
		return
	var s := player.controller.state
	match action:
		0:
			checkpoints.save(s.position, s.velocity, s.yaw, s.pitch, s.is_grounded(), s.is_crouched())
		1:
			var cp := checkpoints.load_current()
			if cp != null:
				player.teleport(cp.position, cp.yaw)
				player.controller.state.velocity = cp.velocity
				player.controller.state.pitch = cp.pitch
		2:
			checkpoints.clear()


# --- Client: applying ---------------------------------------------------------

func _on_event(message: DotNetMessage) -> void:
	var event := message as G2GEvent
	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		G2GEvents.Kind.HELLO:
			_apply_hello(reader)
		G2GEvents.Kind.JOIN:
			_apply_join(reader)
		G2GEvents.Kind.LEAVE:
			var session_id := G2GEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(_player_key(session_id))
			roster_changed.emit(session_id)
		G2GEvents.Kind.MOVEMENT:
			_apply_movement(reader)
		G2GEvents.Kind.MAP:
			var map_id := G2GEvents.read_map(reader)
			if game.maps.current == null or game.maps.current.id != map_id:
				game.change_map(map_id)
		G2GEvents.Kind.TIMER:
			var timer := G2GEvents.read_timer(reader)
			if bool(timer["ok"]):
				_apply_timer(int(timer["player_id"]), timer["state"])
		G2GEvents.Kind.FINISH:
			var finish := G2GEvents.read_finish(reader)
			if bool(finish["ok"]):
				var f: DotTimerNet.Finish = finish["finish"]
				finish_received.emit(int(finish["player_id"]), f.time(1.0 / float(game.tick_rate)), f.rank)
		G2GEvents.Kind.RECORD, G2GEvents.Kind.NOTICE:
			var text := G2GEvents.read_text(reader)
			notice_received.emit(int(text["player_id"]), str(text["text"]))


func _apply_hello(reader: DotNetReader) -> void:
	var hello := G2GEvents.read_hello(reader)
	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])
	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	_apply_movement(DotNetReader.new(hello["movement"]))

	var map_id: StringName = hello["map_id"]
	if map_id != &"" and (game.maps.current == null or game.maps.current.id != map_id):
		game.change_map(map_id)

	hello_received.emit(local_player_id)


func _apply_movement(reader: DotNetReader) -> void:
	var fingerprint := G2GEvents.read_movement(reader, game.config)
	game.apply_movement()

	# The whole reason the config travels rather than the tunables: both ends derive
	# through the same code, and a mismatch is one log line rather than a week of
	# "the netcode feels bad".
	if game.tunables.fingerprint() != fingerprint:
		DotLog.warn(CHANNEL, "movement fingerprint disagrees with the server", {
			"ours": game.tunables.fingerprint(), "theirs": fingerprint
		})


func _apply_join(reader: DotNetReader) -> void:
	var join := G2GEvents.read_join(reader)
	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var peer_id := int(join["peer_id"])
	var id := _player_key(session_id)
	var is_me := session_id == local_player_id

	var player: G2GPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), is_me, join["avatar"])
		if player == null:
			return
		# A client never samples: the client loop hands it commands. It keeps the
		# camera and the HUD's attention if it is the local one.
		player.sampler = null

		# The ghost has no timer anywhere: the server never feeds one, so no TIMER
		# event will ever correct what a mirror started on its own by watching the
		# ghost leave the start pad.
		if session_id == G2GGame.GHOST_SESSION:
			game.timers.remove_player(id)
			player.timer = null

		var identity := _build_entity(player, peer_id)
		var registered := net.registry.register(identity, int(join["net_id"]), net.clock.tick, net.config)
		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			game.remove_player(id)
			return
	else:
		player.display_name = str(join["name"])
		if join["avatar"] != null:
			player.rig.dress(join["avatar"], game.avatar_schema, game.avatar_catalogue)

	game.set_player_style(id, _style_id(int(join["style_index"])))
	game.timers.set_player_track(id, int(join["track"]))

	roster_changed.emit(session_id)


func _apply_timer(session_id: int, state: DotTimerNet.RunState) -> void:
	var player: G2GPlayer = game.players.get(_player_key(session_id))
	if player == null or player.timer == null:
		return

	# Against the ESTIMATED server tick, not the local one: the local tick runs a
	# lead ahead so commands arrive in time, and a HUD counting from it would show
	# every run a flight time longer than the server will file it.
	player.timer.run = DotTimerNet.run_from_state(
		state, net.clock.server_tick(), 1.0 / float(game.tick_rate), _style_id(state.style_index)
	)


func describe() -> Dictionary:
	return {
		"server": net.is_server if net != null else false,
		"players": _behaviours.size(),
		"ready_peers": _ready_peers.size(),
		"local": local_player_id,
		"tick": _tick,
		"link": link.describe() if link != null else {},
	}
