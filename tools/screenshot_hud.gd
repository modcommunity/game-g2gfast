extends SceneTree

## Renders this game's HUD to `screenshots/` so a person can look at it.
##
## [b]This was the only game in the family with no way to look at its own interface.[/b]
## `tools/bsp_preview.sh` renders MAPS and has since it was written; the HUD — the clock,
## the speed, the key display, the stage line, the crosshair — had nothing, and a timer
## HUD is the one surface in this repository a player stares at for an entire run. Four
## of the bugs in this family's list were found by looking at a picture, and two of them
## were a Control laid out inside nothing while every property on it read correctly.
##
## Three frames, because the states differ in the ways that go wrong:
##
## [codeblock]
## hud_run        mid-run, keys down, a stage reference to compare against
## hud_practice   the same run after a checkpoint — PRACTICE has to appear
## hud_notice     a filed time over the top, which is the widest text the HUD draws
## [/codeblock]
##
## Run through `tools/screenshot_hud.sh`. [b]Not `--headless`[/b]: that gives a null
## renderer, a 64 x 64 viewport, and every frame it saves is empty — which is worse than
## no screenshot because it looks like one.

const OUT_DIR := "res://screenshots"

## Frames to let the layout settle before the capture. The HUD reads the player's state
## in `_process`, so a capture on the first frame catches labels that have never been
## filled in — which looks exactly like the bug where they never are.
const SETTLE := 4

var _game: G2GGame = null
var _hud: G2GHud = null
var _player: G2GPlayer = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# The movement actions, because the sampler reads them and an unregistered action
	# pushes an engine error per action per tick. `G2GClient` registers the same set.
	DotFpsSampler.register_default_actions()

	var config := G2GConfig.new()
	config.auto_bhop = true

	_game = G2GGame.new()
	_game.name = "Game"
	_game.config = config
	root.add_child(_game)

	_hud = G2GHud.new()
	_hud.name = "Hud"
	root.add_child(_hud)


func _process(_delta: float) -> bool:
	if _done:
		return true

	# The map load is asynchronous and the HUD's status line names the map, so binding
	# before it is ready draws a dash where the map goes and calls it a picture.
	if _player == null:
		if _game.maps == null or _game.maps.current == null:
			return false

		_player = _game.add_player(&"local", "gamemann", true)
		# The sampler reads real input, and there is none behind xvfb. The commands are
		# written by hand below instead, which is also what makes the key display
		# deterministic rather than whatever the keyboard happened to be doing.
		_player.sampler = null
		_hud.bind(_game, &"local")
		_stage()
		return false

	if _at < _shots.size():
		var shot: Dictionary = _shots[_at]

		# Arrange, THEN settle, THEN capture — in that order and never two of them in
		# one frame. The HUD fills its labels in `_process` and the viewport hands back
		# the frame it last *drew*, so arranging and capturing together photographs the
		# state before the change. The first version did exactly that and produced a
		# `hud_practice` with no PRACTICE on it: the flag was set, the picture was of
		# the frame before it, and nothing about either was wrong enough to notice.
		if not bool(shot["arranged"]):
			var callable: Callable = shot["arrange"]
			callable.call()
			shot["arranged"] = true
			_wait = SETTLE
			return false

		if _wait > 0:
			_wait -= 1
			return false

		_capture(String(shot["name"]))
		_at += 1
		return false

	print("[hud] %d frames in screenshots/" % _shots.size())
	_done = true
	return true


## The three states, and what each is for.
func _stage() -> void:
	_shots = [
		{"name": "hud_run", "arrange": _arrange_run, "arranged": false},
		{"name": "hud_practice", "arrange": _arrange_practice, "arranged": false},
		{"name": "hud_notice", "arrange": _arrange_notice, "arranged": false},
	]


func _arrange_run() -> void:
	# A command with three keys down, so the key display has something to draw and the
	# padding that keeps it from jumping sideways is visible.
	var cmd := DotFpsCommand.new()
	cmd.move = Vector2(1.0, 1.0)
	cmd.buttons = DotFpsCommand.BUTTON_JUMP
	_player.controller.current_command = cmd
	_player.controller.state.velocity = Vector3(14.0, 0.0, 6.0)


func _arrange_practice() -> void:
	# A checkpoint used. The HUD must say PRACTICE from this moment, and a run that
	# quietly stayed recordable after one is the bug this frame is here to show.
	if _player.timer == null:
		push_warning("no timer on the player; PRACTICE cannot be drawn")
		return

	_player.timer.run.used_checkpoints = true


func _arrange_notice() -> void:
	_hud.notice("00:42.31 — rank 3")


func _capture(name: String) -> void:
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := image.save_png(path)

	if err != OK:
		push_error("could not write %s: %d" % [path, err])
		return

	print("[hud] %s  %dx%d" % [path, image.get_width(), image.get_height()])
