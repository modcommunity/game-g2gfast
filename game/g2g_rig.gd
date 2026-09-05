class_name G2GRig
extends Node3D

## The visible character: attachment nodes for the avatar slots, sized to the genre
## hull, and the switch between "I am looking out of it" and "I am looking at it".
##
## [b]The rig is a Node3D under the player body, not the body itself.[/b] The body is
## what the movement drives and what the view rotates for yaw; the rig is what a
## camera looks at. Keeping them apart is what lets first person hide the rig without
## hiding the collider, and third person spin the camera round something that still
## faces where the player is aiming.
##
## Attachment nodes are named for the schema's slots, which is how
## [DotAvatarBuilder.apply] finds them — a slot whose node is missing is a warning
## and an invisible part, never a crash.

## The render layer the local player's own rig is on, so a first-person camera can
## cull it without hiding anybody else's.
const LAYER_LOCAL_BODY := 2

var body_mount: Node3D = null
var head_mount: Node3D = null
var hat_mount: Node3D = null

## Whether the rig is drawn at all. Off in first person for the local player.
var visible_to_owner: bool = true:
	set(value):
		visible_to_owner = value
		_apply_visibility()

## The avatar currently applied, for a HUD or a debug dump.
var avatar: DotAvatar = null

var _crouch: float = 0.0


func _ready() -> void:
	var height := G2GMovement.player_height()
	var eye := height * G2GMovement.eye_fraction()

	body_mount = _mount(G2GAvatars.SLOT_BODY, Vector3(0.0, height * 0.42, 0.0))
	head_mount = _mount(G2GAvatars.SLOT_HEAD, Vector3(0.0, eye, 0.0))
	hat_mount = _mount(G2GAvatars.SLOT_HAT, Vector3(0.0, eye + 0.02, 0.0))


func _mount(slot: StringName, at: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = String(slot)
	node.position = at
	add_child(node)
	return node


## Puts an avatar on the rig.
func dress(
	p_avatar: DotAvatar,
	schema: DotAvatarSchema,
	catalogue: DotAvatarCatalogue
) -> DotResult:
	avatar = p_avatar

	var built := G2GAvatars.apply(p_avatar, self, schema, catalogue)

	_apply_visibility()

	return built


## Squashes the rig for a crouch. [param fraction] is the state's crouch fraction.
##
## Scaled rather than re-posed, because a stock character has no skeleton — and a
## player's own avatar from the platform is a set of parts on mounts, not a rig with
## bones. It reads as a duck at a glance, which is what a timer HUD needs.
func set_crouch(fraction: float) -> void:
	if absf(fraction - _crouch) < 0.001:
		return

	_crouch = fraction

	var stand := G2GUnits.PLAYER_HEIGHT
	var duck := G2GUnits.PLAYER_CROUCH_HEIGHT
	var scale_y := lerpf(1.0, duck / stand, fraction)

	scale = Vector3(1.0, scale_y, 1.0)


func _apply_visibility() -> void:
	# Layers rather than `visible`, so the rig still casts a shadow a first-person
	# player sees on the floor in front of them — which is the one cue for "how tall
	# am I" a first-person view has.
	for child in get_children():
		_set_layers_recursive(child, visible_to_owner)


func _set_layers_recursive(node: Node, owner_sees: bool) -> void:
	if node is VisualInstance3D:
		var visual := node as VisualInstance3D
		# Layer 1 is what every camera sees; LAYER_LOCAL_BODY is what the local
		# first-person camera culls. Both set, so every OTHER camera still draws it.
		visual.layers = 1 | (1 << (LAYER_LOCAL_BODY - 1))

		if node is GeometryInstance3D:
			(node as GeometryInstance3D).cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON if not owner_sees
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			)

	for child in node.get_children():
		_set_layers_recursive(child, owner_sees)


func describe() -> Dictionary:
	return {
		"avatar": str(avatar) if avatar != null else "-",
		"crouch": "%.2f" % _crouch,
		"parts": body_mount.get_child_count() + head_mount.get_child_count()
			+ hat_mount.get_child_count(),
	}
