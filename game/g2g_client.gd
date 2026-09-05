class_name G2GClient
extends Node

## A playable g2gfast: one local player, a camera, a HUD, and the keys.
##
## Separate from [G2GGame], which is the simulation and runs headless. A dedicated
## server never loads this.
##
## Keys: WASD, space (hold, if the server allows auto-bhop), shift to duck, Tab to
## cycle style, M for the next map, R to restart, C / V for practice checkpoints,
## F5 to switch between first and third person, Esc to release the mouse.

const LINK_SERVICE := &"dot_client_link"

var game: G2GGame = null
var player: G2GPlayer = null
var hud: G2GHud = null
var net: DotNetManager = null
var bridge: G2GNetBridge = null
var link: Node = null

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## What this client wears, if a launcher chose one. Published on hello.
@export var avatar: DotAvatar = null

var _offline := true
var _style_index := 0
var _sampler: DotFpsSampler = null


func _ready() -> void:
	link = DotRegistry.get_node_service(LINK_SERVICE)
	_offline = force_offline or link == null or OS.get_cmdline_user_args().has("--offline")

	game = G2GGame.new()
	game.name = "Game"
	var config := G2GConfig.new()
	# A client is never the authority. Its timer is a display; its records go nowhere.
	config.authoritative = _offline
	config.initial_map = config.initial_map if _offline else &""
	game.config = config
	add_child(game)

	if _offline:
		for _i in range(60):
			await get_tree().process_frame
			if game.maps != null and game.maps.current != null:
				break
		player = game.add_player(&"local", "Player", true)
		_watch(&"local")
	else:
		var netted := _build_netcode()
		DotLog.result("g2g.client", "netcode", netted)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	set_process(true)


func _watch(id: StringName) -> void:
	player = game.players.get(id)
	if hud == null:
		hud = G2GHud.new()
		hud.name = "Hud"
		add_child(hud)
	hud.bind(game, id)


func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = 32
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	config.world_extent = 512.0
	net.config = config
	add_child(net)

	var ready_result := net.setup()
	if not ready_result.ok:
		return ready_result

	bridge = G2GNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net, link)
	if not attached.ok:
		return attached

	net.messages.seal()
	bridge.hello_received.connect(_on_hello)
	bridge.finish_received.connect(func(pid: int, time: float, rank: int) -> void:
		if hud != null and pid == bridge.local_player_id:
			hud.notice("%s%s" % [DotTimerRun.format_time(time), " — rank %d" % rank if rank > 0 else ""])
	)
	bridge.notice_received.connect(func(_pid: int, text: String) -> void:
		if hud != null:
			hud.notice(text)
	)

	_sampler = DotFpsSampler.new(game.tunables)
	DotFpsSampler.register_default_actions(_sampler)

	if link.has_method("is_playing") and bool(link.call("is_playing")):
		bridge.ask_ready()
	elif link.has_signal("spawned"):
		link.connect("spawned", bridge.ask_ready, CONNECT_ONE_SHOT)

	if link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	return net.start()


func _on_hello(player_id: int) -> void:
	_watch(StringName("u%d" % player_id))
	if player != null:
		_sampler.tunables = player.controller.tunables
	# The server dressed us from dot-platform's admission if it could; a launcher
	# that resolved one locally through DotAvatarManager sets [member avatar] and it
	# goes up now, to be conformed against the server's schema like any other.
	if avatar != null and bridge != null:
		bridge.publish_avatar(avatar)


func _physics_process(delta: float) -> void:
	if _offline or net == null or not net.is_running() or bridge == null:
		return

	var ticks := net.clock.advance(delta)
	for _i in range(ticks):
		if net.clock.is_synced():
			bridge.client_tick(net.clock.input_tick(), _sampler.sample(delta))


func _process(delta: float) -> void:
	if net != null and not _offline:
		net.interpolate_frame()

	for id in (game.players if game != null else {}):
		(game.players[id] as G2GPlayer).present(delta)


func _unhandled_input(event: InputEvent) -> void:
	if player == null:
		return

	if event is InputEventMouseMotion:
		var sampler := player.sampler if _offline else _sampler
		if sampler != null:
			sampler.handle_event(event)
		return

	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return

	match (event as InputEventKey).physical_keycode:
		KEY_F5:
			if player.camera != null and not player.camera.toggle():
				hud.notice("Third person is not allowed on this server.")
		KEY_TAB:
			var styles := game.timers.styles_in_order()
			_style_index = (_style_index + 1) % styles.size()
			if not _offline:
				bridge.ask_style(styles[_style_index].id)
			elif game.set_player_style(&"local", styles[_style_index].id):
				hud.notice("Style: %s" % styles[_style_index].display_name)
		KEY_R:
			if _offline:
				game.spawn_player(&"local")
			else:
				bridge.ask_restart()
		KEY_M:
			var next := game.maps.rotation.choose(1)
			if next != null:
				game.change_map(next.id)
		KEY_C when not _offline:
			bridge.ask_checkpoint(0)
		KEY_V when not _offline:
			bridge.ask_checkpoint(1)
		KEY_C:
			var s := player.controller.state
			var saved := game.timers.checkpoints_for(&"local").save(
				s.position, s.velocity, s.yaw, s.pitch, s.is_grounded(), s.is_crouched())
			hud.notice("Checkpoint saved" if saved.ok else saved.error.message)
		KEY_V:
			var cp := game.timers.checkpoints_for(&"local").load_current()
			if cp == null:
				hud.notice("No checkpoints. C saves one.")
			else:
				player.teleport(cp.position, cp.yaw)
				player.controller.state.velocity = cp.velocity
				player.controller.state.pitch = cp.pitch
		KEY_ESCAPE:
			Input.mouse_mode = (
				Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				else Input.MOUSE_MODE_CAPTURED
			)
