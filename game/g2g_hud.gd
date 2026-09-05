class_name G2GHud
extends Control

## The competitive-shooter timer HUD: the clock, the speed in u/s, the keys, the strafes.
##
## Composed from [DotTimerHud] rather than replacing it. What this adds is the genre's
## conventions: speed in genre units, a key display (the thing every bhop stream has
## in the corner), the stage, and PRACTICE the moment a checkpoint is used.

var timer_hud: DotTimerHud = null
var _keys: Label = null
var _status: Label = null
var _notice: Label = null
var _notice_until: float = 0.0

var game: G2GGame = null
var player_id: StringName = &"local"


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# set_anchors_preset does NOT set offsets; a Control built in code keeps its zero
	# size otherwise and lays out inside nothing. Cost this family a day in dot-ui.
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	timer_hud = DotTimerHud.new()
	timer_hud.name = "Timer"
	timer_hud.position = Vector2(24.0, 24.0)
	timer_hud.size = Vector2(360.0, 200.0)
	timer_hud.show_speed = false
	timer_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(timer_hud)

	_keys = _label("Keys", Vector2(24.0, 240.0))
	_status = _label("Status", Vector2(24.0, 276.0))
	_notice = _label("Notice", Vector2(24.0, 312.0))


func _label(p_name: String, at: Vector2) -> Label:
	var label := Label.new()
	label.name = p_name
	label.position = at
	label.size = Vector2(800.0, 32.0)
	add_child(label)
	return label


func bind(p_game: G2GGame, p_player: StringName) -> void:
	game = p_game
	player_id = p_player

	game.run_filed.connect(_on_run_filed)
	game.map_ready.connect(func(map: DotMapDef) -> void: notice("Now playing %s" % map.name_or_id()))
	game.movement_changed.connect(
		func(config: G2GConfig) -> void:
			notice("Movement changed: autobhop %s, airaccel %.0f" % [
				"on" if config.auto_bhop else "off", config.air_accelerate
			])
	)
	game.timers.player_staged.connect(
		func(id: StringName, number: int, split: float) -> void:
			if id == player_id:
				notice("Stage %d — %s" % [number, DotTimerRun.format_time(split)])
	)


func notice(text: String) -> void:
	_notice.text = text
	_notice_until = Time.get_ticks_msec() / 1000.0 + 4.0


func _process(_delta: float) -> void:
	if game == null:
		return

	if Time.get_ticks_msec() / 1000.0 > _notice_until:
		_notice.text = ""

	var player: G2GPlayer = game.players.get(player_id)
	if player == null:
		return

	var state := player.controller.state

	timer_hud.style_name = player.timer_style.display_name if player.timer_style != null else ""
	timer_hud.show_run(player.timer.run if player.timer != null else null, player.speed(),
		player.controller.stats.to_dictionary())

	# The key display. Read from the state's own buttons — what the SIMULATION saw —
	# rather than from Input, so it shows what the server would show for a replay.
	var cmd := player.controller.current_command
	var move := cmd.move if cmd != null else Vector2.ZERO
	var buttons := cmd.buttons if cmd != null else 0

	_keys.text = "%s %s %s %s   %s %s     %s u/s" % [
		"W" if move.y > 0.1 else "·",
		"A" if move.x < -0.1 else "·",
		"S" if move.y < -0.1 else "·",
		"D" if move.x > 0.1 else "·",
		"JUMP" if buttons & DotFpsCommand.BUTTON_JUMP else "····",
		"DUCK" if buttons & DotFpsCommand.BUTTON_CROUCH else "····",
		G2GUnits.format_speed(player.speed()),
	]

	var parts := PackedStringArray([
		game.maps.current.name_or_id() if game.maps.current != null else "-",
		DotTimerTrack.name_of(player.timer.track) if player.timer != null else "-",
		game.maps.time_limit.formatted_remaining(),
		"autobhop %s" % ("on" if game.config.auto_bhop else "off"),
		player.camera.describe()["mode"] if player.camera != null else "",
	])

	if player.timer != null and player.timer.run.used_checkpoints:
		parts.append("PRACTICE")

	if state.is_grounded():
		parts.append("ground")

	_status.text = "   ·   ".join(parts)


func _on_run_filed(id: StringName, run: DotTimerRun, rank: int, reason: String) -> void:
	if id != player_id:
		return
	if reason != "":
		notice("%s — not recorded: %s" % [run.formatted_time(), reason])
	else:
		notice("%s — rank %d" % [run.formatted_time(), rank])
