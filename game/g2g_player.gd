class_name G2GPlayer
extends Node3D

## One player: the movement, the rig they are drawn as, the camera they look through,
## and their timer.
##
## [b]The bridge between the addons, which is where the bugs are.[/b] What this file
## alone knows:
##
## - the timer is ticked from the movement loop, after the move, with the position the
##   move produced;
## - a style has two halves and they are applied together;
## - the rig is drawn from the state — crouch, yaw — and never the other way round;
## - a camera mode is cosmetic: the controller aims from the eye whichever is active.
##
## Positions are metres by the time they reach here. Everything genre-unit-shaped
## was converted in [G2GMovement].

const CHANNEL := "g2g.player"

signal finished(run: DotTimerRun)

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## Whether a command is sampled from the input devices each tick. The person at the
## keyboard only; a bot and every remote player leave it off.
@export var samples_input: bool = false

## Whether this player owns a camera. Only the local player does; a remote player's
## copy is drawn and never looked through.
@export var has_camera: bool = false

var controller: DotFpsController = null
var sampler: DotFpsSampler = null
var rig: G2GRig = null
var camera: G2GCamera = null

## This player's timer. Owned by the game's [DotTimerManager].
var timer: DotTimer = null

var movement_style: DotFpsStyle = null
var timer_style: DotTimerStyle = null

## Set on a ghost: the player is driven by a replay rather than by commands, and
## its timer is never fed. See [method G2GGame.spawn_ghost].
var replay: DotTimerReplayPlayer = null

## How long a ghost stands at the finish before starting over.
const REPLAY_HOLD_SEC := 2.0

var _replay_hold: float = 0.0
var _replay_previous: Vector3 = Vector3.ZERO
var _replay_moving: bool = false

## The tunables this player was built with, before any style. See [method set_movement].
var base_tunables: DotFpsTunables = null

var tick_rate: int = 128


func _ready() -> void:
	if base_tunables == null:
		base_tunables = G2GMovement.tunables_for(G2GConfig.new())

	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# EXTERNAL: the game owns the tick, so the timer can be fed the position the move
	# just produced. See game-playground's CLAUDE.md for the ordering argument.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = base_tunables
	# body_ref left unset so it resolves to this node. `of_self()` would resolve to
	# the CONTROLLER, a plain Node, and setup() would refuse — the player would then
	# simply never move, with nine failures pointing anywhere but here.
	add_child(controller)

	controller.simulated.connect(_on_simulated)

	rig = G2GRig.new()
	rig.name = "Rig"
	add_child(rig)

	if has_camera:
		camera = G2GCamera.new()
		camera.name = "Camera"
		add_child(camera)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		DotFpsSampler.register_default_actions(sampler)


# --- Movement and style ----------------------------------------------------

## Hands the player a new base movement, keeping whatever style they are on.
##
## What a cvar change does to every player at once. The controller rebuilds its motor
## from the new base; the run is the game's to abandon, which it does before calling
## this.
func set_movement(tunables: DotFpsTunables) -> DotResult:
	base_tunables = tunables
	controller.tunables = tunables

	# `set_style` derives from the controller's stored base, which was the OLD
	# tunables. Clearing that lets setup() adopt the new base, and re-applying the
	# style then derives from it — rather than compounding on a base that has moved.
	controller._base_tunables = null

	var result := controller.set_style(movement_style)

	if sampler != null:
		sampler.tunables = controller.tunables

	return result


## Both halves of a style, together.
func set_style(movement: DotFpsStyle, ranking: DotTimerStyle) -> DotResult:
	movement_style = movement
	timer_style = ranking

	if timer != null:
		timer.set_style(ranking)

	var result := controller.set_style(movement)

	if sampler != null:
		sampler.tunables = controller.tunables

	return result


func teleport(to: Vector3, yaw: float = INF) -> void:
	controller.state.position = to
	controller.state.velocity = Vector3.ZERO

	if is_finite(yaw):
		controller.state.yaw = yaw

		if sampler != null:
			sampler.yaw = yaw

	global_position = to

	if timer != null:
		timer.stop(DotTimer.REASON_TELEPORT)


# --- The tick --------------------------------------------------------------

func simulate(tick: int, delta: float) -> void:
	if replay != null:
		_play_replay(delta)
		return

	if sampler != null:
		controller.apply_command(sampler.sample(delta))

	controller.simulate_tick(tick, delta)


## A ghost's tick: the replay's pose goes straight into the state, so everything
## that reads the state — the rig, the HUD's speed, the net behaviour — sees a
## player, and nothing that moves one runs.
func _play_replay(delta: float) -> void:
	replay.advance(delta)
	var frame := replay.sample()
	if frame == null:
		return

	var s := controller.state

	# Derived from the last frame, not stored: a replay carries poses, and the speed
	# a HUD or a spectator reads has to come from the difference between two of them.
	# A flag rather than a zero-vector sentinel, because a replay that passes through
	# the world origin is an ordinary replay.
	s.velocity = (
		(frame.position - _replay_previous) / maxf(delta, 0.0001) if _replay_moving
		else Vector3.ZERO
	)
	_replay_moving = true
	_replay_previous = frame.position
	s.position = frame.position
	s.yaw = frame.yaw
	s.pitch = frame.pitch
	global_position = frame.position

	if replay.progress() >= 1.0:
		_replay_hold += delta
		_replay_moving = false
		if _replay_hold >= REPLAY_HOLD_SEC:
			_replay_hold = 0.0
			_replay_moving = false
			replay.seek(0.0)


func _on_simulated(_tick: int, state: DotFpsState) -> void:
	global_position = state.position

	if timer == null:
		return

	if (
		movement_style != null
		and movement_style.prespeed_limit > 0.0
		and timer.in_zone(DotTimerZone.Kind.START)
	):
		state.velocity = DotTimerRules.clamp_prespeed(
			state.velocity, G2GUnits.to_metres(movement_style.prespeed_limit)
		)

	var speed_zone := timer.effect(DotTimerZone.Kind.SPEED_LIMIT)

	if speed_zone != null:
		state.velocity = DotTimerRules.apply_speed_limit(state.velocity, speed_zone)


func fill_sample(sample: DotTimerSample) -> void:
	var state := controller.state
	sample.position = state.position
	sample.velocity = state.velocity
	sample.grounded = state.is_grounded()
	sample.alive = true
	sample.buttons = state.previous_buttons


# --- Drawing ---------------------------------------------------------------

## Draws the state. Per frame, from the client, never from the tick.
func present(delta: float) -> void:
	var state := controller.state

	rig.set_crouch(state.crouch_fraction)
	rig.global_basis = Basis(Vector3.UP, deg_to_rad(state.yaw))

	if camera != null:
		var eye := controller.motor.eye_position(state) if controller.motor != null else state.position
		camera.global_position = eye
		camera.global_basis = Basis(Vector3.UP, deg_to_rad(state.yaw))
		camera.look(state.pitch, delta)
		rig.visible_to_owner = camera.is_third_person()


func speed() -> float:
	return controller.state.horizontal_speed()


func eye_position() -> Vector3:
	return controller.motor.eye_position(controller.state)


func aim_direction() -> Vector3:
	return DotFpsMotor.aim_for(controller.state.yaw, controller.state.pitch)


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"name": display_name,
		"style": String(movement_style.id) if movement_style != null else "-",
		"speed": "%s u/s" % G2GUnits.format_speed(speed()),
		"view": camera.describe()["mode"] if camera != null else "-",
		"run": str(timer.run) if timer != null else "-",
	}
