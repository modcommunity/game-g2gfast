extends RigidBody3D

## A placeable block, generated from three numbers rather than modelled.
##
## [b]What a timer server actually uses props for.[/b] Not a sandbox — game-playground
## is the sandbox. An admin building a practice line, a temporary boost block on a
## section people keep failing, a marker at the spot everybody asks about: those are
## the things a records server places, and every one of them wants to be frozen where
## it was put rather than to roll away.
##
## So the interesting default here is the opposite of a sandbox's: a prop is spawned
## FROZEN. `DotPhysGun.set_frozen` is what unfreezes one, which is the same call a
## sandbox uses to freeze one, from the other side.
##
## The mass is not set here. [method DotPropSpawner.spawn] puts the catalogue's mass on
## the body before it enters the tree, and a value written in the scene would be the
## second copy of a number this family has already shipped a bug about.

@export var half_size: Vector3 = Vector3(0.5, 0.5, 0.5)

@export var tint: Color = Color(0.55, 0.60, 0.70)

@export var visible_body: bool = true

## Whether the block is placed frozen. See the class note.
@export var starts_frozen: bool = true


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	collision_layer = 1
	collision_mask = 1
	continuous_cd = true
	can_sleep = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = starts_frozen

	var collider := CollisionShape3D.new()
	collider.name = "Shape"
	var box := BoxShape3D.new()
	box.size = half_size * 2.0
	collider.shape = box
	add_child(collider)

	if not visible_body:
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.75

	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "Mesh"
	var mesh := BoxMesh.new()
	mesh.size = half_size * 2.0
	mesh_node.mesh = mesh
	mesh_node.material_override = material
	add_child(mesh_node)
