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
var _crosshair: DotCrosshair = null
var _notice_until: float = 0.0

var game: G2GGame = null
var player_id: StringName = &"local"

## How far up from the bottom the notice line starts, in pixels.
##
## The clock block's own margin is 92 and it draws about 90 tall, so anything below 182
## is inside it. This is that plus a gap, in one place, so moving the clock moves this.
const NOTICE_CLEARANCE := 196.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# set_anchors_preset does NOT set offsets; a Control built in code keeps its zero
	# size otherwise and lays out inside nothing. Cost this family a day in dot-ui.
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# THE WHOLE RECT, not a box in the corner.
	#
	# `DotTimerHud` places its own block in a corner of whatever rect it is given, so
	# the rect is the AREA it lays out inside rather than the block. Handing it the
	# 360 x 200 it used to have would pin an overlay to the corner of a box in the
	# corner, which is the thing being fixed.
	timer_hud = DotTimerHud.new()
	timer_hud.name = "Timer"
	timer_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	timer_hud.offset_left = 0.0
	timer_hud.offset_top = 0.0
	timer_hud.offset_right = 0.0
	timer_hud.offset_bottom = 0.0
	timer_hud.corner = DotTimerHud.Placement.BOTTOM_CENTRE
	timer_hud.margin = Vector2(24.0, 92.0)
	timer_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(timer_hud)

	# The key display, directly under the clock, which is where every bhop stream in
	# this genre has had it for fifteen years. Centred rather than left-aligned so it
	# reads as part of the same block; monospaced-by-padding, because a proportional
	# font makes the four keys jump sideways as they light up.
	_keys = _label("Keys", HORIZONTAL_ALIGNMENT_CENTER)
	_keys.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_keys.offset_left = 0.0
	_keys.offset_right = 0.0
	_keys.offset_top = -80.0
	_keys.offset_bottom = -52.0

	# Reference rather than gameplay: the map, the track, the time limit, the rules
	# in force. Along the top, out of the way of both the crosshair and the clock.
	_status = _label("Status", HORIZONTAL_ALIGNMENT_CENTER)
	_status.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_status.offset_left = 0.0
	_status.offset_right = 0.0
	_status.offset_top = 14.0
	_status.offset_bottom = 40.0
	_status.modulate = Color(1.0, 1.0, 1.0, 0.62)

	# A crosshair, which this game did not have.
	#
	# It was survivable while the HUD was a column of text down the left: there was
	# something to look at. With the clock moved under the centre there is nothing at
	# all in the middle of the screen, and a first-person game with an empty centre
	# reads as broken rather than as clean. dot-ui draws one rather than shipping art,
	# which is why it can be used here without an asset.
	_crosshair = DotCrosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.offset_left = 0.0
	_crosshair.offset_top = 0.0
	_crosshair.offset_right = 0.0
	_crosshair.offset_bottom = 0.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)

	# Things that just happened: a finish, a rank, a map change, a cvar an admin
	# moved. Above the clock, where a player's eye already is.
	#
	# [b]Clear of the clock, and the number is derived from the clock rather than
	# guessed.[/b] It sat at -160 and the clock block is 92 up from the bottom and about
	# 90 tall, so a finish time was drawn straight through "0:00.000" — two numbers in
	# the same font at the same size overlapping to the pixel, which reads as a font
	# glitch rather than as a layout bug. Nothing could assert it: both Labels had the
	# right text, the right size and the right anchors, and a rect that overlaps another
	# rect is a legitimate rect. `tools/screenshot_hud.sh` found it on its first run.
	_notice = _label("Notice", HORIZONTAL_ALIGNMENT_CENTER)
	_notice.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_notice.offset_left = -600.0
	_notice.offset_right = 600.0
	_notice.offset_top = -(NOTICE_CLEARANCE + 26.0)
	_notice.offset_bottom = -NOTICE_CLEARANCE


func _label(p_name: String, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.name = p_name
	label.horizontal_alignment = align
	# `set_anchors_preset` does NOT set offsets — every caller above sets its own four
	# — and a Label that never got them keeps the zero size it was created with while
	# every one of its properties reads correctly. This family has shipped that twice.
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
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

	# How many stages this map's track has, and the player's own best split at each,
	# so the clock block can say "Stage 2 / 5  -0.42" rather than only "Stage 2".
	#
	# Refreshed on a map change and on a filed run, which are the only two things that
	# change either — NOT per frame. `stage_splits_for` goes to the store, and a store
	# is a database handle behind an interface written to be asynchronous; asking it
	# 128 times a second for a number that changes twice an hour is the cost this HUD
	# would never notice locally and a server would.
	game.map_ready.connect(func(_map: DotMapDef) -> void: refresh_stage_reference())
	game.run_filed.connect(
		func(id: StringName, _run: DotTimerRun, _rank: int, _reason: String) -> void:
			if id == player_id:
				refresh_stage_reference()
	)

	refresh_stage_reference()


## Re-reads what the stage line counts and compares against.
##
## Public because a net bridge changes the track under the HUD — a player pressing T
## for the bonus is on a different track with a different stage count — and there is
## no signal for that.
func refresh_stage_reference() -> void:
	if game == null or game.timers == null:
		return

	var timer := game.timers.timer_for(player_id)

	if timer == null:
		timer_hud.set_stage_reference(0, {})
		return

	timer_hud.set_stage_reference(
		game.timers.stage_count(timer.track), game.timers.stage_splits_for(player_id)
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

	# The speed is NOT repeated here. `DotTimerHud` draws it in the block this line
	# sits under, and the same number twice, six pixels apart, in two different
	# formats, is the shape the old layout had.
	_keys.text = "%s %s %s %s    %s  %s" % [
		"W" if move.y > 0.1 else "·",
		"A" if move.x < -0.1 else "·",
		"S" if move.y < -0.1 else "·",
		"D" if move.x > 0.1 else "·",
		"JUMP" if buttons & DotFpsCommand.BUTTON_JUMP else "····",
		"DUCK" if buttons & DotFpsCommand.BUTTON_CROUCH else "····",
	]

	# The track is not repeated here either — `DotTimerHud` draws it beside the style,
	# where a player reads the two together.
	var parts := PackedStringArray([
		game.maps.current.name_or_id() if game.maps.current != null else "-",
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
