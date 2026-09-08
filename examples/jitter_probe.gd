extends Node

## Measures what a rendered frame actually shows, and fails if it is not smooth.
##
## [b]The report this exists for was "very jittery in the browser", and nothing in any
## suite could see it.[/b] Every check in this repository asserts a simulated value —
## a position after N ticks, a run time, a correction rate — and all of those were
## right. What was wrong was the mapping from the simulation to the screen, which no
## assertion on the simulation can reach.
##
## Four configurations of one constant-velocity motion, drawn the way
## [method G2GPlayer.present] draws it and sampled once per rendered frame. A perfectly
## smooth render moves the same distance every frame; anything else is the judder.
##
##   1. the browser as it shipped — engine 60, server 128, drawn at the last whole tick
##   2. the engine put on the server's rate, still drawn at the last whole tick
##   3. drawn between ticks, but with the engine left at 60
##   4. both: the engine on the server's rate AND drawn between ticks
##
## [b]Only the fourth is smooth, and that is the point of running all four.[/b] Either
## half alone measures as no better than doing nothing, so either half alone would have
## been shipped as a fix and the report would have come back.
##
## The blend is [method DotFpsController.render_state] itself rather than a copy of its
## arithmetic — a probe that reimplements what it is checking cannot fail when the real
## one breaks.

const RUN_SPEED_MS := 250.0 * 0.01905  # 250 u/s, the genre's run speed, in metres
const SERVER_TICK_RATE := 128
const RENDER_FPS := 60
const FRAMES := 240

## Frames to discard while the clock settles before measuring.
const SETTLE_FRAMES := 60

## How uniform a frame step has to be to count as smooth, as a share of the mean.
##
## Generous on purpose: the failure this guards against measures 47%, and a threshold
## that has to be argued about is one nobody trusts.
const SMOOTH_ENOUGH := 0.05

var _controller: DotFpsController = null
var _clock: DotNetClock = null
var _drawn: Array[float] = []
var _interpolated := false
var _label := ""
var _frames := 0
var _failures := 0
var _pending: Array = []
var _lines: Array[String] = []


func _ready() -> void:
	Engine.max_fps = RENDER_FPS

	# A controller with no world: this measures the render path, not the motor, so the
	# state is advanced by hand at a known speed. EXTERNAL is what a netcode uses and
	# is the drive `render_state` used to refuse.
	# Under a Node3D, because the controller resolves its body to its parent and says
	# so loudly otherwise — and a suite that prints a red line every run is one whose
	# red lines stop being read.
	var body := Node3D.new()
	body.name = "Body"
	add_child(body)

	_controller = DotFpsController.new()
	_controller.name = "Controller"
	_controller.drive = DotFpsController.Drive.EXTERNAL
	_controller.tick_rate = SERVER_TICK_RATE
	body.add_child(_controller)

	_pending = [
		["the browser as it shipped: engine 60, server 128, drawn at the last tick", 60, false, false],
		["the engine on the server's 128, still drawn at the last tick", 128, false, false],
		["drawn between ticks, but the engine left at 60", 60, true, false],
		["both: the engine on 128 AND drawn between ticks", 128, true, true],
	]
	_next()


func _next() -> void:
	if _pending.is_empty():
		for line in _lines:
			print(line)
		print("\n%s" % ("smooth, and only in the configuration that ships" if _failures == 0
			else "%d configuration(s) measured wrong" % _failures))
		get_tree().quit(1 if _failures > 0 else 0)
		return

	var case: Array = _pending.pop_front()
	_label = str(case[0])
	Engine.physics_ticks_per_second = int(case[1])
	_interpolated = bool(case[2])

	_clock = DotNetClock.new(SERVER_TICK_RATE, false)
	_clock.sync_from_server(0, 0.0)
	_controller.state.position = Vector3.ZERO
	_controller._previous_state.copy_from(_controller.state)
	_drawn.clear()
	_frames = 0
	set_meta("must_be_smooth", bool(case[3]))


func _physics_process(delta: float) -> void:
	if _clock == null:
		return

	# Exactly `G2GClient._physics_process`: ask the clock how many ticks this frame is
	# worth and run that many. With the engine on the server's rate it is always one;
	# at 60 against 128 it alternates two and three, which is the whole bug.
	for _i in range(_clock.advance(delta)):
		_controller._previous_state.copy_from(_controller.state)
		_controller.state.position += Vector3(0.0, 0.0, RUN_SPEED_MS / float(SERVER_TICK_RATE))


func _process(_delta: float) -> void:
	if _clock == null:
		return

	# What present() draws, through the real function in both cases: render_state with
	# no argument derives the fraction, and the raw tick state is render_state(0.0)'s
	# other end — asked for explicitly so both paths go through the same code.
	var shown := (
		_controller.render_state().position.z if _interpolated
		else _controller.state.position.z
	)

	_drawn.append(shown)
	_frames += 1

	if _frames >= FRAMES:
		_report()
		_next()


func _report() -> void:
	var steps: Array[float] = []
	for i in range(SETTLE_FRAMES, _drawn.size()):
		steps.append(_drawn[i] - _drawn[i - 1])

	var smallest := INF
	var largest := -INF
	var total := 0.0
	for s in steps:
		smallest = minf(smallest, s)
		largest = maxf(largest, s)
		total += s
	var mean := total / float(maxi(1, steps.size()))
	var spread := (largest - smallest) / maxf(mean, 1e-9)

	var must_be_smooth := bool(get_meta("must_be_smooth", false))
	var is_smooth := spread <= SMOOTH_ENOUGH
	var ok := is_smooth == must_be_smooth

	if not ok:
		_failures += 1

	_lines.append("\n%s %s" % ["  ok  " if ok else " FAIL ", _label])
	_lines.append("        frame moves the view: min %.1f mm  max %.1f mm  mean %.1f mm" % [
		smallest * 1000.0, largest * 1000.0, mean * 1000.0])
	_lines.append("        spread: %.0f%% of a mean step  (expected %s)" % [
		spread * 100.0, "smooth" if must_be_smooth else "judder"])
