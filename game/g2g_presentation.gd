extends Node

const G2GPaths := preload("g2g_paths.gd")

## Settings, audio, effects and a console, on a client whose whole output is a number.
##
## [b]Every decision in this file is downstream of one sentence: a player who came to run
## must not be stopped by anything added for a player who came to do something else.[/b]
## That is this game's own rule and it settles what would otherwise be arguments:
##
## - **Camera shake defaults to zero here, and to one everywhere else.** A surf ramp is a
##   precision input at 20 m/s; shaking the camera for a landing is not atmosphere, it is
##   taking the run away. It is still a setting, because a player doing deathmatch on the
##   same server may want it.
## - **The flash is off by default** for the same reason and with the same switch.
## - **Nothing on the fx budget is allowed to matter.** An effect never changes the
##   simulation, so a frame budget dropping one cannot change a time — which is the
##   property that makes the whole addon safe on a timer server.
##
## The one thing audio genuinely adds here is **the landing**: a bunny-hop is a rhythm,
## and a rhythm you can only see is one you have to watch your feet for.

const CHANNEL := "g2g.presentation"

const SCHEMA_VERSION := 1
const SOUND_DIR := "res://audio"
static var FX_DIR := G2GPaths.rebase("res://scenes/fx")

var settings: DotSettingsManager = null
var audio: DotAudioManager = null
var fx: DotFxManager = null
var console: DotConsoleController = null
var console_panel: DotConsolePanel = null

## The in-game chat box. See [method _build_chat].
var chat_window: DotChatWindow = null

var client: Node = null

var _layer: CanvasLayer = null
var _chat_layer: CanvasLayer = null

## Whether the server said something else is carrying chat. See [method set_chat_relayed].
var _chat_relayed: bool = false
var _was_grounded := true


func setup() -> DotResult:
	var settled := _build_settings()
	if not settled.ok:
		return settled
	var heard := _build_audio()
	if not heard.ok:
		return heard
	var drawn := _build_fx()
	if not drawn.ok:
		return drawn
	var consoled := _build_console()
	if not consoled.ok:
		return consoled
	_build_chat()
	apply_all()
	return DotResult.success(null)


func apply_all() -> void:
	for key in settings.schema.keys():
		_on_setting_changed(key, settings.get_value(key), &"applied")


# --- Settings ---------------------------------------------------------------

static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"sfx_volume", 1.0, 0.0, 1.0, &"audio"))

	# ACCOUNT scope, and here it matters more than anywhere else in the family: a runner's
	# sensitivity is muscle memory built over months, and a player who has to find it again
	# on a new server has lost the run they came for.
	s.add(DotSettingsDef.number(&"sensitivity", 2.5, 0.05, 20.0, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"raw_input", true, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	# The style is remembered per person, not per machine. Somebody who runs sideways
	# runs sideways everywhere.
	s.add(DotSettingsDef.text(&"preferred_style", "normal", &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Which style to ask for on joining. The server decides."))

	s.add(DotSettingsDef.boolean(&"show_speed", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"show_splits", true, &"running").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	# Chat. ACCOUNT scope for all three, for the reason the sensitivity above has it: a
	# runner who found their key once should never have to find it again.
	s.add(DotSettingsDef.choice(
		&"chat_window",
		&"auto",
		[&"auto", &"on", &"off"] as Array[StringName],
		&"chat"
	).with_scope(DotSettingsDef.Scope.ACCOUNT).with_description(
		"auto hides the box on a server already carrying chat somewhere the player can "
		+ "see it; on always draws it; off never does."
	))
	s.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.binding(&"chat_team_key", "U", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	s.add(DotSettingsDef.integer(&"field_of_view", 110, 70, 130, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.integer(&"fx_quality", 3, 0, 3, &"video"))

	# [b]Zero by default, which is the opposite of every other game here.[/b] A surf ramp
	# is a precision input at speed; shaking the camera for a landing is taking the run
	# away. It is still a setting because the same server runs a deathmatch layer.
	s.add(DotSettingsDef.number(&"shake_scale", 0.0, 0.0, 2.0, &"accessibility")
		.with_description(
			"Zero by default on a timer server: a shaken camera is a lost run."
		))
	s.add(DotSettingsDef.boolean(&"allow_flashes", false, &"accessibility")
		.with_description("Off by default here, for the same reason as the shake."))
	return s


func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	settings.schema = schema()
	settings.local_store = DotSettingsStoreFile.new("user://g2g_settings")
	settings.app_namespace = &"game_g2gfast"
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("g2gfast's settings")
	settings.changed.connect(_on_setting_changed)
	return DotResult.success(null)


func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	match key:
		&"master_volume":
			audio.mixer.master = float(value)
			audio.mixer.apply_to_buses()
		&"sfx_volume":
			audio.mixer.sfx = float(value)
			audio.mixer.apply_to_buses()
		&"shake_scale":
			fx.config.shake_scale = float(value)
		&"allow_flashes":
			fx.config.allow_flashes = bool(value)
		&"fx_quality":
			fx.config.quality = int(value)
		&"chat_window":
			_apply_chat_visibility()
		&"chat_open_key":
			_bind_chat(chat_window.open_action if chat_window != null else &"", str(value))
		&"chat_team_key":
			_bind_chat(chat_window.team_action if chat_window != null else &"", str(value))
		_:
			pass


# --- Audio ------------------------------------------------------------------

## What a timer server makes a noise about.
##
## Short, and every entry earns its place by telling a runner something they cannot see:
##
## - **the landing**, which is the rhythm of a bunny-hop and the one thing here that is
##   genuinely feedback rather than decoration;
## - **the start, the split and the finish**, which are the run;
## - **a personal best**, which is the only reason anybody is here.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	var land := DotAudioDef.new()
	land.id = &"land"
	land.path = "%s/land.ogg" % SOUND_DIR
	land.bus = &"SFX"
	# Short, because a hop is a hundred and fifty milliseconds and a landing sound that
	# outlasts the next jump is a blur rather than a beat.
	land.cooldown_ms = 60
	land.max_concurrent = 2
	land.priority = 70
	# Pitched by nothing here: the caller passes the speed, because how fast you were
	# going when you landed is the information.
	c.add(land)

	var jump := DotAudioDef.new()
	jump.id = &"jump"
	jump.path = "%s/jump.ogg" % SOUND_DIR
	jump.bus = &"SFX"
	jump.cooldown_ms = 60
	jump.max_concurrent = 2
	jump.priority = 50
	c.add(jump)

	for id in [&"timer_start", &"timer_split", &"timer_finish", &"personal_best"]:
		var d := DotAudioDef.new()
		d.id = id
		d.path = "%s/%s.ogg" % [SOUND_DIR, id]
		d.bus = &"UI"
		# Never refused for a cheaper sound. These four ARE the game.
		d.priority = 100
		d.max_concurrent = 1
		c.add(d)

	var teleport := DotAudioDef.new()
	teleport.id = &"teleport"
	teleport.path = "%s/teleport.ogg" % SOUND_DIR
	teleport.bus = &"UI"
	teleport.priority = 80
	c.add(teleport)

	return c


func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	# Small. There is one player making noises and the rest is a timer.
	audio.voices = 12
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("g2gfast's audio")
	return DotResult.success(null)


# --- Effects ----------------------------------------------------------------

static func fx_catalogue() -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var start := DotFxDef.new()
	start.id = &"start_gate"
	start.scene_path = "%s/start_gate.tscn" % FX_DIR
	start.lifetime_ms = 600
	start.cost = 2
	start.priority = 80
	start.max_distance = 0.0
	c.add(start)

	var finish := DotFxDef.new()
	finish.id = &"finish_gate"
	finish.scene_path = "%s/finish_gate.tscn" % FX_DIR
	finish.lifetime_ms = 1200
	finish.cost = 4
	finish.priority = 90
	finish.max_distance = 0.0
	c.add(finish)

	# A tint on a personal best, off by default with everything else. Somebody who wants
	# a celebration can have one; nobody gets it in the middle of a run they did not ask
	# for it in.
	var best := DotFxDef.new()
	best.id = &"personal_best"
	best.kind = DotFxDef.Kind.SCREEN
	best.flash_peak = 0.18
	best.flash_colour = Color(0.45, 1.0, 0.55)
	best.flash_decay_ms = 500
	c.add(best)

	var land := DotFxDef.new()
	land.id = &"land_shake"
	land.kind = DotFxDef.Kind.SHAKE
	land.shake_trauma = 0.18
	c.add(land)

	return c


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.quality = settings.get_int(&"fx_quality", 3)
	fx.config.shake_scale = settings.get_float(&"shake_scale", 0.0)
	fx.config.allow_flashes = settings.get_bool(&"allow_flashes", false)
	fx.config.max_decals = 0
	# Deliberately small. Nothing here is allowed to cost a frame on a server where a
	# frame is a tick and a tick is 7.8 ms of somebody's time.
	fx.config.frame_budget = 24
	add_child(fx)

	var res := fx.setup()
	if not res.ok:
		return res.wrap("g2gfast's effects")
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

func _build_console() -> DotResult:
	console = DotConsoleController.new()
	console.name = "Console"
	console.config = DotConsoleConfig.new()
	console.config.mirror_log = true
	console.config.mirror_from = DotLog.Level.INFO
	add_child(console)

	var res := console.setup()
	if not res.ok:
		return res.wrap("g2gfast's console")

	var local := DotConsoleLocal.new()
	local.add_command(&"help", "List what this client can do", func(_a: PackedStringArray) -> Variant:
		var lines := PackedStringArray(["Client commands:"])
		for n in console.all_names():
			lines.append("  %-20s %s" % [n, console.help_for(n)])
		return lines
	)
	local.add_command(&"quit", "Leave", func(_a: PackedStringArray) -> Variant:
		get_tree().quit()
		return null
	)
	local.add_command(&"settings", "Show every setting", func(_a: PackedStringArray) -> Variant:
		return settings.describe_lines()
	)
	local.add_command(&"clear", "Empty the scrollback", func(_a: PackedStringArray) -> Variant:
		console.buffer.clear()
		return null
	)
	for key in settings.schema.keys():
		var def := settings.schema.find(key)
		local.bind_setting(key, settings, def.description if def != null else "")
	console.add_source(local)

	# [b]A remote source with a PREFIX, which is this game's own decision.[/b] Everywhere
	# else in the family the server's console is added unprefixed and catches whatever the
	# client did not claim. Here the two consoles share names that mean opposite things --
	# `!s3` on a client is a local navigation and on a server is a teleport that ends a
	# run -- and an unprefixed remote console is how somebody types something meant for
	# their own client and loses the run they were three stages into.
	var server: Object = DotRegistry.get_service(&"dot_server")
	if server != null and server.get("console") != null:
		var bridge := DotConsoleBridge.wrap(server.get("console"), "server")
		console.add_source(bridge)

	_layer = CanvasLayer.new()
	_layer.name = "ConsoleLayer"
	_layer.layer = 128
	add_child(_layer)

	console_panel = DotConsolePanel.new()
	console_panel.name = "ConsolePanel"
	console_panel.controller = console
	_layer.add_child(console_panel)
	return DotResult.success(null)


# --- Chat -------------------------------------------------------------------

## The box a runner types in, and the three settings that decide it.
##
## [b]This game could receive a chat line and could not send one.[/b] `DotChatClient` held
## the history, the HUD drew the notice, and there was no key anywhere that opened
## anything to type in — so a player could be talked to and could not talk back.
##
## Bottom left, at the default inset: this HUD keeps its clock and its key display along
## the bottom CENTRE and its status line along the top, so the corner is free.
func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 100
	add_child(_chat_layer)

	chat_window = DotChatWindow.new()
	chat_window.name = "ChatWindow"
	chat_window.open_action = &"g2g_chat"
	chat_window.team_action = &"g2g_chat_team"
	chat_window.channels = [
		{"id": &"all", "label": "Say", "colour": Color(0.88, 0.90, 0.94)},
		{"id": &"team", "label": "Say (TEAM)", "colour": Color(0.55, 0.85, 0.60), "team": true},
	]
	_chat_layer.add_child(chat_window)


## Puts one binding from the settings document onto its action.
##
## Empty is left alone rather than applied: a settings file somebody cleared the field in
## would otherwise unbind chat with no way to get it back from inside the game.
func _bind_chat(action: StringName, text: String) -> void:
	if action == &"" or text.strip_edges() == "":
		return

	var bound := DotInputBinding.apply(action, text)

	if bound == "":
		DotLog.warn(CHANNEL, "a chat key was not understood", {
			"action": String(action), "binding": text
		})


## The server said whether anything else is carrying this conversation.
func set_chat_relayed(relayed: bool) -> void:
	if _chat_relayed == relayed:
		return

	_chat_relayed = relayed
	_apply_chat_visibility()


## Resolves the three-way setting against what the server said.
##
## `on` is both halves at once — a relayed server AND a box in front of the game. `off` is
## a player who chats somewhere else. `auto` draws it unless this server is already putting
## these lines somewhere this player can see them. In every case the log keeps drawing what
## other people said: off means "you type somewhere else", never "you are out of it".
func _apply_chat_visibility() -> void:
	if chat_window == null or settings == null:
		return

	match StringName(str(settings.get_value(&"chat_window"))):
		&"on":
			chat_window.enabled = true
		&"off":
			chat_window.enabled = false
		_:
			chat_window.enabled = not _chat_relayed


# --- What the game asks for -------------------------------------------------

func present(delta: float, eye: Vector3, forward: Vector3) -> void:
	audio.listener_position = eye
	fx.viewer_position = eye
	fx.viewer_forward = forward
	fx.advance(delta)


func camera_shake() -> Vector3:
	return fx.shake.offset()


## Whether something on screen owns the keyboard right now.
##
## [b]The chat box belongs here for the reason the console does[/b], and on a timer server
## it is worse than elsewhere: a client that keeps reading movement while somebody types
## does not merely walk them into a wall, it ends a run they have been building for
## minutes. Nobody may lose a personal best by saying "gg".
func swallows_input() -> bool:
	if console_panel != null and console_panel.has_keyboard_focus():
		return true

	return chat_window != null and chat_window.is_open()


## Called once a tick with the local player's movement state.
##
## [b]Watched rather than listened for, and it is the same argument this family made about
## eating in a 2D arena:[/b] a landing fires on the authority, which on a netted client is
## somewhere else — so a client that hooked a signal would be silent online and perfectly
## noisy offline, which is the kind of difference nothing catches. What a player perceives
## is their own feet touching the ground, and that arrives either way.
func watch_movement(grounded: bool, speed: float, at: Vector3) -> void:
	if grounded and not _was_grounded:
		# The pitch is the speed. A runner cannot see their own velocity while looking at
		# a ramp, and a landing that sounds different at 400 units and at 1200 is the
		# cheapest speedometer there is.
		audio.play_at(&"land", at, 1.0, clampf(0.75 + speed / 2000.0, 0.6, 1.6))
		fx.spawn(&"land_shake", Transform3D.IDENTITY)
	elif _was_grounded and not grounded:
		audio.play(&"jump")
	_was_grounded = grounded


func on_run_started(at: Vector3) -> void:
	var t := Transform3D.IDENTITY
	t.origin = at
	audio.play(&"timer_start")
	fx.spawn(&"start_gate", t)


func on_split() -> void:
	audio.play(&"timer_split")


func on_run_finished(at: Vector3, personal_best: bool) -> void:
	var t := Transform3D.IDENTITY
	t.origin = at
	audio.play(&"timer_finish")
	fx.spawn(&"finish_gate", t)
	if personal_best:
		audio.play(&"personal_best")
		# Refused unless the player asked for flashes, which they have not by default.
		fx.flash(&"personal_best")


func on_teleported() -> void:
	audio.play(&"teleport")
	# Everything drawn about where you were is about somewhere you are not.
	fx.clear()


func on_map_changed() -> void:
	fx.clear()
	_was_grounded = true


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("g2gfast's presentation layer")
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	out.append_array(fx.describe_lines())

	if chat_window != null:
		out.append("chat box: %s" % str(chat_window.describe()))

	return out
