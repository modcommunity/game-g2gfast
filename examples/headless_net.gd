extends Node
## game-g2gfast's netcode, end to end, in one process.
##
## A server game and a client game, each with its own [DotNetManager] and
## [G2GNetBridge], with a lossy loopback where the socket would be. Exits non-zero on
## any failure. Everything here that could run over a real socket already has, in
## dot-2d-hungry; this proves the bridge, not dot-net.
##
## [b]The client's tick lead is hand-stamped[/b] (INPUT_LEAD): a command for tick N
## has to be in the server's hands before it simulates N, and with no clock to
## synchronise against the harness does the arithmetic itself.

const CLIENT_PEER := 2
const SESSION := 7
const INPUT_LEAD := 2
const SNAPSHOT_RATE := 32

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server_game: G2GGame = null
var _client_game: G2GGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: G2GNetBridge = null
var _client_bridge: G2GNetBridge = null

var _to_client: Array[Dictionary] = []
var _to_server: Array[Dictionary] = []
var _drop_every: int = 0
var _snapshot_count: int = 0
var _tick: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: netcode")
	print("")
	_test_command_wire()
	_test_movement_wire()
	_test_hello_wire()
	if await _build():
		_test_handshake()
		await _test_prediction()
		await _test_timer()
		await _test_finish()
		_test_movement_change()
		_test_style_and_track()
		_test_avatar()
		await _test_lossy()
		await _test_map_change()
		_test_ghost()
		_test_leave()
	_report()


func _report() -> void:
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  FAIL " + f)
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok   " + what)
	else:
		_failed += 1
		_failures.append(what + (": " + detail if detail != "" else ""))
		print("  FAIL " + what + (": " + detail if detail != "" else ""))


func _section(name: String) -> void:
	print("")
	print(name)


# --- Wire ------------------------------------------------------------------

func _test_command_wire() -> void:
	_section("a command survives the wire")
	var packet := G2GNetCommand.new()
	packet.tick = 77
	packet.delta = 1.0 / 128.0
	packet.move.move = Vector2(-1.0, 0.5)
	packet.move.yaw = 45.0
	packet.move.pitch = -20.0
	packet.move.set_button(DotFpsCommand.BUTTON_JUMP, true)
	packet.move.set_button(DotFpsCommand.BUTTON_CROUCH, true)

	var writer := DotNetWriter.new()
	packet.write(writer)
	var back := G2GNetCommand.new()
	back.read(DotNetReader.new(writer.to_bytes()))

	_check(back.tick == 77, "tick")
	_check(back.move.move.distance_to(packet.move.move) < 0.01, "move axes", str(back.move.move))
	_check(absf(back.move.yaw - 45.0) < 0.2 and absf(back.move.pitch + 20.0) < 0.5, "view angles", "%s %s" % [back.move.yaw, back.move.pitch])
	_check(back.move.is_pressed(DotFpsCommand.BUTTON_JUMP) and back.move.is_pressed(DotFpsCommand.BUTTON_CROUCH), "buttons")
	# Quantised once is quantised for good: a second trip must change nothing.
	var again := DotNetWriter.new()
	back.write(again)
	var twice := G2GNetCommand.new()
	twice.read(DotNetReader.new(again.to_bytes()))
	_check(twice.equals(back), "and is stable under a second trip, which is what input compression rests on")


func _test_movement_wire() -> void:
	_section("the movement configuration travels")
	var config := G2GConfig.new()
	config.air_accelerate = 1000.0
	config.gravity = 600.0
	config.auto_bhop = false

	var reader := DotNetReader.new(G2GEvents.write_movement(config))
	var received := G2GConfig.new()
	var fingerprint := G2GEvents.read_movement(reader, received)

	_check(received.air_accelerate == 1000.0 and received.gravity == 600.0, "cvars arrive")
	_check(received.auto_bhop == false, "and the autobhop switch")
	_check(G2GMovement.tunables_for(received).fingerprint() == fingerprint,
		"and the receiver derives the same tunables the sender fingerprinted")
	_check(G2GMovement.tunables_for(config).fingerprint() == fingerprint, "which are the sender's")


func _test_hello_wire() -> void:
	_section("hello")
	var config := G2GConfig.new()
	var reader := DotNetReader.new(G2GEvents.write_hello(128, 7, 2, 4096, &"surf_g2g_intro", config))
	var hello := G2GEvents.read_hello(reader)
	_check(bool(hello["ok"]), "parses")
	_check(int(hello["tick_rate"]) == 128 and int(hello["player_id"]) == 7 and int(hello["peer_id"]) == 2, "with ids")
	_check(int(hello["server_tick"]) == 4096 and hello["map_id"] == &"surf_g2g_intro", "the tick and the map")


# --- Bringing both halves up ---------------------------------------------------

func _make_game(server: bool, scope: StringName, parent: Node) -> G2GGame:
	var config := G2GConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"bhop_g2g_intro"
	config.authoritative = server

	var game := G2GGame.new()
	game.name = "Game"
	game.config = config
	game.service_scope = scope
	parent.add_child(game)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_lag_compensation = false
	config.enable_prediction = true
	config.world_extent = 512.0
	manager.config = config

	parent.add_child(manager)
	manager.setup()
	return manager


func _build() -> bool:
	_section("bringing both halves up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_game = _make_game(true, &"server", server_side)
	_client_game = _make_game(false, &"client", client_side)

	for _i in range(120):
		await get_tree().process_frame
		if _server_game.maps.current != null and _client_game.maps.current != null:
			break

	_check(_server_game.maps.current != null and _client_game.maps.current != null, "both games load the map")
	_check(_server_game.tick_rate == _client_game.tick_rate, "at one tick rate")

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate)

	_server_bridge = G2GNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = G2GNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	# The link mirrors a node named "Server" on both ends: the manager is one.
	var attached := _server_bridge.attach(_server_game, _server_net, _server_net)
	_check(attached.ok, "the server bridge attaches", str(attached.error) if not attached.ok else "")
	var client_attached := _client_bridge.attach(_client_game, _client_net, _client_net)
	_check(client_attached.ok, "the client bridge attaches", str(client_attached.error) if not client_attached.ok else "")

	var wrong := G2GNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_game, _server_net, self)
	_check(not refused.ok and refused.error.code == DotError.CODE_STATE, "a client game on a server manager is refused")
	wrong.queue_free()

	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the message schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	# What a real client wires to DotClientLink.ping_ms(). Without it the clock
	# believes the link is instant and every command arrives a flight time late.
	_client_bridge.rtt_source = func() -> float:
		return 40.0

	_check(_server_game.external_tick, "the server game hands its tick to the bridge")
	_check(_client_game.external_tick, "and so does the client's, which predicts and interpolates instead")

	return attached.ok and client_attached.ok


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if method == &"snapshot":
		_snapshot_count += 1
		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return
	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()
	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])
	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## A request and its answer: the answer is queued during the first flush and
## delivered by the second.
func _exchange() -> void:
	_flush()
	_flush()


func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	_client_net.clock.advance(1.0 / float(_client_game.tick_rate))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		_step(command)


func _forward() -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	return c


func _server_player() -> G2GPlayer:
	return _server_game.players.get(&"u%d" % SESSION)


func _client_player() -> G2GPlayer:
	return _client_game.players.get(&"u%d" % SESSION)


# --- Tests -----------------------------------------------------------------

func _test_handshake() -> void:
	_section("a client joins")

	var hellos := []
	_client_bridge.hello_received.connect(func(id: int) -> void: hellos.append(id))

	var added := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(added.ok, "the server adds the player", str(added.error) if not added.ok else "")
	_check(_server_player() != null and not _server_player().samples_input, "as a remote player on the server")
	_check(not _server_net.peers().has(CLIENT_PEER), "and sends nothing until the client says it can receive")
	_flush()
	_check(_client_player() == null, "so the client has heard nothing yet")

	_client_bridge.ask_ready()
	_exchange()

	_check(_server_net.peers().has(CLIENT_PEER), "asking admits them")
	_check(hellos == [SESSION], "and the client is told who it is", str(hellos))
	_check(_client_bridge.local_player_id == SESSION, "which the bridge remembers")
	_check(_client_player() != null and _client_player().samples_input, "the client mirrors itself as the local player")
	_check(_client_player() != null and _client_player().sampler == null, "which the bridge drives rather than the devices")
	_check(_client_game.tunables.fingerprint() == _server_game.tunables.fingerprint(), "with the server's movement")
	_check(_client_player() != null and _client_player().timer != null and not _client_player().timer.authoritative,
		"and a timer that mirrors rather than decides")

	var mine := _client_bridge.behaviour_for(SESSION)
	_check(mine != null and mine.identity != null and mine.identity.is_predicted(), "the local player is predicted")
	_check(mine != null and mine.identity.net_id == _server_bridge.behaviour_for(SESSION).identity.net_id,
		"under the server's entity id")


func _test_prediction() -> void:
	_section("prediction converges")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(4)
	_flush()

	var forward := _forward()
	_steps(96, forward)

	_check(G2GUnits.to_units(server.speed()) > 200.0, "the server player moves on the client's input", G2GUnits.format_speed(server.speed()))
	_check(client.global_position.distance_to(server.global_position) < 0.5, "and the client shows it where the server has it",
		"%.3f m apart" % client.global_position.distance_to(server.global_position))
	var rate := _client_net.predictor.correction_rate()
	_check(rate < 0.1, "with almost no corrections", "%.3f" % rate)
	_check(absf(_client_net.stats.rtt_percentile(0.5) - 40.0) < 0.01, "and the clock has been told how long the link is",
		"%.1f ms" % _client_net.stats.rtt_percentile(0.5))
	await get_tree().process_frame


func _test_timer() -> void:
	_section("the timer replicates")
	var server := _server_player()
	var client := _client_player()
	_server_game.spawn_player(server.player_id)
	_steps(2)

	_check(server.timer.in_zone(DotTimerZone.Kind.START), "the server player spawns on the start pad")

	var hold := _forward()
	hold.set_button(DotFpsCommand.BUTTON_JUMP, true)
	_steps(120, _forward())
	_steps(120, hold)

	_check(server.timer.run.is_running(), "the server's run starts when its player hops off the pad",
		"in start: %s, %s" % [server.timer.in_zone(DotTimerZone.Kind.START), G2GUnits.format_speed(server.speed())])
	_check(client.timer.run.is_running(), "and the client's mirror is running too")
	_check(client.timer.run.style_id == server.timer.run.style_id, "in the same style")
	var drift := absf(client.timer.run.time() - server.timer.run.time())
	_check(drift < 0.05, "reading the same time", "%.3f s apart" % drift)
	await get_tree().process_frame


func _test_finish() -> void:
	_section("a finish reaches the client")
	var server := _server_player()
	var finishes := []
	var notices := []
	_client_bridge.finish_received.connect(func(id: int, time: float, rank: int) -> void: finishes.append([id, time, rank]))
	_client_bridge.notice_received.connect(func(_id: int, text: String) -> void: notices.append(text))

	# A fresh run walked off the pad on the ground, so its length is known: the
	# hopping run above may have fallen at a gap and been respawned since.
	_server_game.spawn_player(server.player_id)
	_steps(2)
	_steps(260, _forward())
	_check(server.timer.run.is_running(), "a walked run is going", str(server.timer.describe()))
	var before := server.timer.run.time()

	var end := _server_game.timers.zones.first_of_kind(DotTimerZone.Kind.END, 0)
	server.controller.state.position = end.centre() + Vector3.UP * 0.3
	server.controller.state.velocity = Vector3(0.0, 0.0, -3.0)
	_steps(6, _forward())
	for _i in range(4):
		await get_tree().process_frame
	_flush()

	var who := _server_game.timers.player(server.player_id)
	var filed := who.last_finished if who != null else null
	_check(finishes.size() == 1, "once", str(finishes))
	_check(finishes.size() == 1 and finishes[0][0] == SESSION and float(finishes[0][1]) >= before,
		"with a time", "%s before=%.3f notices=%s" % [finishes, before, notices])
	_check(finishes.size() == 1 and filed != null and absf(float(finishes[0][1]) - filed.time()) < 0.0001,
		"which is the server's own to the sub-tick fraction",
		"%s vs %s" % [finishes[0][1] if finishes.size() == 1 else "none", filed.time() if filed else "none"])
	_check(finishes.size() == 1 and (int(finishes[0][2]) >= 1 or not notices.is_empty()),
		"ranked, or told why not", str(notices))
	_check(not _client_player().timer.run.is_running(), "and the client's mirror stops")


func _test_movement_change() -> void:
	_section("changing the movement under a live client")
	_server_game.config.air_accelerate = 150.0
	_server_game.apply_movement()
	_flush()
	_check(_client_game.config.air_accelerate == 150.0, "the cvar reaches the client")
	_check(_client_game.tunables.fingerprint() == _server_game.tunables.fingerprint(), "and both derive the same tunables")
	_steps(2)


func _test_style_and_track() -> void:
	_section("asking for a style and a track")
	_client_bridge.ask_style(&"sideways")
	_exchange()
	_check(_server_player().timer_style != null and _server_player().timer_style.id == &"sideways", "the server switches",
		str(_server_player().timer_style.id) if _server_player().timer_style else "")
	_check(_client_player().timer_style != null and _client_player().timer_style.id == &"sideways", "and tells the client")

	_client_bridge.ask_track(DotTimerTrack.BONUS_FIRST)
	_exchange()
	_check(_server_player().timer.track == DotTimerTrack.BONUS_FIRST, "a bonus track, on the server")
	_check(_client_player().timer.track == DotTimerTrack.BONUS_FIRST, "and on the client")

	_client_bridge.ask_track(99)
	_exchange()
	_check(_server_player().timer.track == DotTimerTrack.BONUS_FIRST, "an invalid track is ignored")

	_client_bridge.ask_style(&"normal")
	_client_bridge.ask_track(DotTimerTrack.MAIN)
	_exchange()


func _test_avatar() -> void:
	_section("an avatar published by the client")
	var avatar := G2GAvatars.stock_avatar(&"someone-else")
	var before := _server_player().rig.avatar.to_dict() if _server_player().rig.avatar != null else {}
	_client_bridge.publish_avatar(avatar)
	_exchange()
	var after := _server_player().rig.avatar.to_dict() if _server_player().rig.avatar != null else {}
	_check(after != before or avatar.to_dict() == before, "reaches the server's rig")
	_check(_client_player().rig.avatar != null and _client_player().rig.avatar.to_dict() == after, "and comes back to the client")


func _test_lossy() -> void:
	_section("losing every third snapshot")
	_server_game.spawn_player(_server_player().player_id)
	_steps(4)
	_drop_every = 3
	_steps(128, _forward())
	_drop_every = 0
	var apart := _client_player().global_position.distance_to(_server_player().global_position)
	_check(apart < 0.5, "the client still shows the server's position", "%.3f m" % apart)
	_check(_client_net.predictor.correction_rate() < 0.15, "and prediction still converges", "%.3f" % _client_net.predictor.correction_rate())
	await get_tree().process_frame


func _test_map_change() -> void:
	_section("changing the map")
	var changed: DotResult = await _server_game.change_map(&"surf_g2g_intro")
	_check(changed.ok, "the server changes", str(changed.error) if not changed.ok else "")
	_flush()
	for _i in range(60):
		await get_tree().process_frame
		if _client_game.maps.current != null and _client_game.maps.current.id == &"surf_g2g_intro":
			break
	_check(_client_game.maps.current != null and _client_game.maps.current.id == &"surf_g2g_intro", "and the client follows")
	_check(_client_player() != null, "keeping its players")
	_steps(4)
	_check(_client_player().global_position.distance_to(_server_player().global_position) < 1.0, "at the new spawn",
		"%.3f m" % _client_player().global_position.distance_to(_server_player().global_position))


func _test_ghost() -> void:
	_section("the record's ghost")
	var map_id: StringName = _server_game.maps.current.id
	var replay := DotTimerReplay.new()
	replay.map_id = map_id
	replay.tick_rate = _server_game.tick_rate
	replay.time = 2.0
	replay.player_name = "Ghost"
	for i in range(_server_game.tick_rate * 2):
		var t := float(i) / float(_server_game.tick_rate * 2 - 1)
		replay.append(Vector3(0.0, 1.0, 7.0 - 20.0 * t), 0.0, 0.0)
	var record := DotTimerRecord.new()
	record.map_id = map_id
	record.style_id = &"normal"
	record.player_name = "Ghost"
	record.time = 2.0
	_server_game.replays.offer(replay, record)

	var ghost := _server_game.spawn_ghost()
	_check(ghost != null, "the server spawns it")
	_check(_server_bridge.behaviour_for(G2GGame.GHOST_SESSION) != null, "and the bridge adopts it as a bot")
	_exchange()
	_check(_client_game.players.has(G2GGame.GHOST_ID), "the client sees it")
	var mirrored: G2GPlayer = _client_game.players.get(G2GGame.GHOST_ID)
	var before := mirrored.global_position if mirrored else Vector3.ZERO
	_steps(64)
	for _i in range(3):
		_client_net.interpolate_frame()
	var after := mirrored.global_position if mirrored else Vector3.ZERO
	_check(before.distance_to(after) > 0.5, "running", "%.2f m" % before.distance_to(after))
	_check(mirrored != null and mirrored.replay == null and mirrored.timer == null,
		"as a remote player with no timer to mislead a HUD")

	_server_game.remove_player(G2GGame.GHOST_ID)
	_exchange()
	_check(_server_bridge.behaviour_for(G2GGame.GHOST_SESSION) == null, "removing it releases the entity")
	_check(not _client_game.players.has(G2GGame.GHOST_ID), "and the client drops it")


func _test_leave() -> void:
	_section("a bot, and leaving")
	var roster := []
	_client_bridge.roster_changed.connect(func(id: int) -> void: roster.append(id))

	var bot := _server_bridge.add_player(0, 9, "Bot")
	_check(bot.ok, "a bot joins on the server with no peer behind it", str(bot.error) if not bot.ok else "")
	_check(not _server_net.peers().has(0), "and is not a peer, because 0 is the broadcast address")
	_exchange()
	_check(_client_game.players.has(&"u9"), "the client mirrors it", str(roster))
	_steps(4)

	_server_bridge.remove_player(9)
	_exchange()
	_check(not _client_game.players.has(&"u9") and roster.has(9), "and drops it when it leaves", str(roster))

	_server_bridge.remove_peer(CLIENT_PEER)
	_flush()
	_check(_server_player() == null, "the server drops a leaving peer's player")
	_check(not _server_net.peers().has(CLIENT_PEER), "and the peer")
