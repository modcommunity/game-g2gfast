class_name G2GCamera
extends Node3D

## First person and third person, with the genre's field of view.
##
## [b]Two cameras, one active, and the switch is a cull mask.[/b] The first-person
## camera sits at the eye and culls the local rig's layer so the player does not see
## the inside of their own head; the third-person camera sits on a [SpringArm3D]
## behind and above and draws everything. Both are always present, so switching is a
## `current` flip and not a rebuild — which matters because a player toggles it
## mid-run and a rebuilt camera would drop a frame at the worst moment.
##
## [b]The field of view is the genre's[/b]: [code]fov_desired[/code] is horizontal at
## 4:3 and converted with [method G2GUnits.horizontal_fov_to_vertical], so 90 looks like
## 90 does in those games on every aspect ratio. Handing 90 to Godot's vertical
## fov is the obvious thing, and produces a view nobody with that muscle memory can
## aim in.
##
## Third person adds nothing the simulation can see. The controller aims from the
## eye whichever camera is active; the player is looking at their own character
## rather than through it, and where the character is aiming is the same place.

enum Mode {
	FIRST_PERSON,
	THIRD_PERSON,
}

## Distance the third-person camera sits behind the player, in metres.
##
## About 100 genre units, which is what a third-person camera distance defaults to.
@export_range(0.5, 10.0, 0.1) var third_person_distance: float = 1.9

## How far above the eye the third-person pivot sits.
@export_range(-1.0, 2.0, 0.05) var third_person_height: float = 0.1

## Whether the third-person view is permitted at all. Server-decided.
var allow_third_person: bool = true

var mode: Mode = Mode.FIRST_PERSON

var first: Camera3D = null
var third: Camera3D = null
var arm: SpringArm3D = null

## The familiar fov_desired. Applied to both cameras through the conversion.
var fov_desired: float = 90.0:
	set(value):
		fov_desired = value
		_apply_fov()

## Signalled so a HUD can say which view is on.
signal mode_changed(mode: Mode)


func _ready() -> void:
	first = Camera3D.new()
	first.name = "FirstPerson"
	# Everything except the local rig's layer.
	first.cull_mask = ~(1 << (G2GRig.LAYER_LOCAL_BODY - 1)) & 0xFFFFF
	add_child(first)

	arm = SpringArm3D.new()
	arm.name = "Arm"
	arm.spring_length = third_person_distance
	arm.margin = 0.15
	# Collides with the world, not with the player's own hull — the arm starts inside
	# it and would otherwise clamp to zero length every frame.
	arm.collision_mask = 1
	arm.position = Vector3(0.0, third_person_height, 0.0)
	add_child(arm)

	third = Camera3D.new()
	third.name = "ThirdPerson"
	third.cull_mask = 0xFFFFF
	arm.add_child(third)

	_apply_fov()
	set_mode(mode)


func _apply_fov() -> void:
	var vertical := G2GUnits.horizontal_fov_to_vertical(fov_desired)

	for camera in [first, third]:
		if camera == null:
			continue
		camera.keep_aspect = Camera3D.KEEP_HEIGHT
		camera.fov = vertical


## Switches view. False when third person is not permitted here.
func set_mode(new_mode: Mode) -> bool:
	if new_mode == Mode.THIRD_PERSON and not allow_third_person:
		return false

	mode = new_mode

	if first != null:
		first.current = mode == Mode.FIRST_PERSON
	if third != null:
		third.current = mode == Mode.THIRD_PERSON

	mode_changed.emit(mode)

	return true


func toggle() -> bool:
	return set_mode(
		Mode.THIRD_PERSON if mode == Mode.FIRST_PERSON else Mode.FIRST_PERSON
	)


func is_third_person() -> bool:
	return mode == Mode.THIRD_PERSON


## The active camera, for whatever needs one.
func active() -> Camera3D:
	return third if mode == Mode.THIRD_PERSON else first


## Points both cameras. [param pitch] and [param yaw] are the player's view, in degrees.
##
## The rig pitches nothing; only cameras do. The third-person arm pitches about the
## pivot so looking down swings the camera up and over, which is what every
## third-person game does and what a spring arm gives for free.
func look(pitch: float, delta: float) -> void:
	if first != null:
		first.rotation = Vector3(deg_to_rad(pitch), 0.0, 0.0)

	if arm != null:
		arm.rotation = Vector3(deg_to_rad(pitch), 0.0, 0.0)
		# Eased toward the configured length, so a camera pushed in by a wall comes
		# back out rather than snapping. Frame-rate independent by construction.
		arm.spring_length = lerpf(
			arm.spring_length, third_person_distance,
			1.0 - exp(-8.0 * delta)
		)


## The vertical field of view actually in use, for a HUD or a test.
func vertical_fov() -> float:
	return first.fov if first != null else G2GUnits.horizontal_fov_to_vertical(fov_desired)


func describe() -> Dictionary:
	return {
		"mode": Mode.keys()[mode],
		"fov_desired": fov_desired,
		"vertical_fov": "%.2f" % vertical_fov(),
		"third_person_allowed": allow_third_person,
	}
