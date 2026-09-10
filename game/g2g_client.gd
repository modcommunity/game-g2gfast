class_name G2GClient
extends Node

## A playable g2gfast: one local player, a camera, a HUD, and the keys.
##
## Separate from [G2GGame], which is the simulation and runs headless. A dedicated
## server never loads this.
##
## Keys: WASD, space (hold, if the server allows auto-bhop), shift to duck, Tab to
## cycle style, M for the next map, R to restart, C / V for practice checkpoints,
## F5 to switch between first and third person, Esc to release the mouse, click to
## take it back — which is also how a browser player captures it in the first place,
## because pointer lock needs a real user gesture. See [method _grab_mouse].

const LINK_SERVICE := &"dot_client_link"

var game: G2GGame = null
var player: G2GPlayer = null
var hud: G2GHud = null
var net: DotNetManager = null
var bridge: G2GNetBridge = null
var link: Node = null

## The server browser: dot-browser's client half.
##
## Built whether or not this client is connected, because looking for a server is what
## you do when you are not on one. `!servers` lists what it found.
var servers: G2GBrowser = null

## Chat and voice: the client halves of what [G2GServices] runs on the server.
##
## Null offline, deliberately. Both are about a server telling this client something,
## and an offline game has nobody to be told by — building them anyway would open a
## microphone in a single-player run.
var extras: G2GClientExtras = null

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## What this client wears, if a launcher chose one. Published on hello.
@export var avatar: DotAvatar = null

var _offline := true
var _style_index := 0
var _sampler: DotFpsSampler = null

## Whether the cursor is waiting for a click before it can be captured. Web only.
var _awaiting_click := false

## Who [member player] should be, whether or not that player exists yet.
##
## See [method _watch]: on a networked client the id is known one message before the
## player it names.
var _watch_id: StringName = &""


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

	# Connected before anything can create a player. `JOIN` is what creates the local
	# one and it arrives after `HELLO` has already said who we are — see [method _watch].
	game.player_added.connect(_on_player_added)

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

	# The server browser. Built on every client, connected or not: looking for a
	# server is what you do when you are not on one, and a browser that only existed
	# while you were already playing would be a browser nobody could reach.
	servers = G2GBrowser.new()
	servers.name = "Servers"
	add_child(servers)

	var listed := servers.setup()
	DotLog.result("g2g.client", "the server browser", listed)

	_grab_mouse()
	set_process(true)


## Lists what the browser found, on the HUD. What `!servers` and F3 both call.
##
## [b]A chat command rather than a screen, and game-arena has a screen.[/b] That game
## has a [DotScreenStack]; this client has a HUD and a keyboard, and the genre's answer
## to "show me the servers" is a chat trigger, because that is what a bhop player's
## fingers already do. The list model, the sources, the filters and the favourites are
## the same addon doing the same work either way.
func show_servers() -> void:
	if servers == null or hud == null:
		return

	hud.notice("Looking for servers…")

	var found: DotResult = await servers.refresh()

	if not found.ok:
		hud.notice(found.error.message)
		return

	for line in servers.lines():
		hud.notice(line)


## Hides and captures the cursor, or arranges for a click to do it.
##
## [b]A browser will not hide the cursor because a scene asked it to.[/b] Pointer lock
## needs transient user activation — a real click — and `_ready()` is the one moment in
## a client's life that is guaranteed not to have one. The request is refused, and it is
## refused SILENTLY: `Input.mouse_mode` reads back as CAPTURED, the cursor stays on
## screen, and the view still turns, so nothing anywhere reports a problem. What the
## player gets is a mouse that leaves the window mid-run.
##
## This is the family's own rule about deployment shapes, on a capability nothing had
## needed yet: game-hungario is the only other browser client and it is 2D — it reads
## the cursor's position and never locks it — so g2gfast is the first thing here that
## has ever asked a browser for pointer lock.
##
## Desktop has no such rule and captures immediately, because a player who launched a
## first-person game should not have to click their own window first.
func _grab_mouse() -> void:
	if not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_awaiting_click = true
	_say_click_to_play()


## Tells the player the one thing they have to do, once there is a HUD to say it on.
##
## `_ready()` builds the HUD only on the offline path; a networked client gets one when
## the server says who it is, which is several hundred milliseconds later. Saying it in
## both places rather than once is why this is a function.
func _say_click_to_play() -> void:
	if _awaiting_click and hud != null:
		hud.notice("Click to play")


## Follows a player: the camera, the HUD, and everything the keys act on.
##
## [b]The id arrives one message before the player does.[/b] `HELLO` says who you are and
## `JOIN` is what creates you — `G2GNetBridge._apply_join` calls `game.add_player` — so a
## networked client that resolved [member player] here and never again held null for the
## whole session. Nothing errored: the HUD binds by id and worked, movement is polled
## from the [InputMap] by `DotFpsSampler.sample` and worked, and the camera follows the
## entity rather than this reference. What did not work was every line below the
## `player == null` guard in [method _unhandled_input] — which is mouse look, F5, Tab, R,
## C, V and M. **The whole keyboard and the whole mouse, on a client that otherwise
## looked fine.**
##
## `headless_net` never instantiates this class — it drives two bridges directly — so
## nothing in the suite had ever been through this path.
func _watch(id: StringName) -> void:
	_watch_id = id
	_adopt(game.players.get(id))

	if hud == null:
		hud = G2GHud.new()
		hud.name = "Hud"
		add_child(hud)
	hud.bind(game, id)
	_say_click_to_play()


## The player we are waiting for has been created. Fires for every player; ours is one.
func _on_player_added(added: G2GPlayer) -> void:
	if player == null and added != null and added.player_id == _watch_id:
		_adopt(added)


func _adopt(candidate: G2GPlayer) -> void:
	if candidate == null:
		return

	player = candidate

	# The sampler turns the view at the rate this player's style says, and until there
	# is a player to ask it is on the game's own tunables. Done here rather than in
	# `_on_hello` for the same reason as everything else in this function: at hello
	# there is nobody to ask.
	if _sampler != null:
		_sampler.tunables = player.controller.tunables


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

	# The client halves. Built here rather than in `_ready` because both need the
	# bridge, and there is no bridge offline.
	extras = G2GClientExtras.new()
	extras.name = "Extras"
	add_child(extras)

	var extra := extras.attach(bridge, game)
	DotLog.result("g2g.client", "the client's chat and voice", extra)

	extras.line_received.connect(func(text: String) -> void:
		if hud != null:
			hud.notice(text)
	)

	# [b]Where chat actually arrives.[/b] `G2GServices` routes a line through dot-chat
	# and then hands it to dot-server's manager to put on the wire, so on this end it
	# lands on `DotClientLink.chat_received` — not on anything dot-chat owns. Without
	# this connection the client's `DotChatClient` is a history nothing feeds.
	if link != null and link.has_signal("chat_received"):
		link.connect("chat_received", extras.receive_wire)

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


## Set by a headless suite to answer [method mouse_drives_view] without a display
## server. Left null in play, where the real mouse mode is the only honest answer.
var mouse_capture_override: Variant = null


## Whether the pointer is currently a look input rather than a pointer.
##
## [b]Only while the cursor is actually captured.[/b] KEY_ESCAPE releases it, and on the
## web [member _awaiting_click] leaves it released before the first click too — in both
## of those states the pointer is a pointer, so spending its motion on the view turns
## the player away from the "click to play" notice they are being asked to click.
## `game-arena` guarded this from the start; this file and `game-playground` did not.
##
## [b]A method with an override rather than a read of `Input.mouse_mode` at the call
## site, because that read cannot be tested here.[/b] The dummy display server pins the
## mode to `MOUSE_MODE_VISIBLE` and drops every write to it without erroring, so a suite
## can neither put a client into the state a player plays in nor out of it — which is
## why arena's identical guard has never been exercised by anything.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	# [b]Before the `player == null` guard, deliberately.[/b] A browser player clicks
	# while the world is still loading more often than not, and a click swallowed
	# because no player exists yet is a click that never captures the cursor — after
	# which the only affordance the game offers is one it has already ignored.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_awaiting_click = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			if hud != null:
				hud.notice("")
			return

	if player == null:
		return

	if event is InputEventMouseMotion:
		if not mouse_drives_view():
			return

		var sampler := player.sampler if _offline else _sampler
		if sampler != null:
			sampler.handle_event(event)
		return

	if not (event is InputEventKey) or event.is_echo():
		return

	# Push to talk, handled BEFORE the "is this a press" filter below, because a talk
	# key needs its release as much as its press: a key whose release nobody reads is
	# a microphone that never closes.
	#
	# [b]K, not V.[/b] V is this game's second checkpoint key and has been since the
	# client was written; the genre's own voice key is unbound here because the genre
	# binds it per player. K is what is left that nothing else claims.
	if (event as InputEventKey).physical_keycode == KEY_K:
		if extras != null:
			extras.set_talking(event.is_pressed())

		return

	if not event.is_pressed():
		return

	match (event as InputEventKey).physical_keycode:
		KEY_F3:
			show_servers()
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
			# [b]Release only, and a click is the way back.[/b] Escape is how a browser
			# itself exits pointer lock, and it then refuses to re-enter it for about a
			# second afterwards — so a toggle bound to Escape works on the desktop and,
			# on the web, silently does nothing every other press. One key that releases
			# and one gesture that captures is the same contract on both.
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			if DotPlatform.is_web():
				_awaiting_click = true
				_say_click_to_play()
