class_name G2GGeometry
extends RefCounted

## Dev-textured collision geometry in code, in genre units.
##
## [b]Every argument is in genre units[/b] and converted here, so a map file reads
## like a brush list: a 64-unit-tall block is [code]64[/code], not
## [code]1.2192[/code]. A surf ramp built as "128 wide at 60°" is a ramp a mapper
## who has built one before can read.
##
## Deliberately duplicated from game-playground rather than shared: the family rule
## is that games copy what they need, because a shared helper is a dependency and
## these two games will diverge.

const COLOUR_FLOOR := Color(0.32, 0.34, 0.38)
const COLOUR_RAMP := Color(0.26, 0.42, 0.55)
const COLOUR_START := Color(0.22, 0.55, 0.28)
const COLOUR_END := Color(0.60, 0.24, 0.24)
const COLOUR_PLATFORM := Color(0.42, 0.40, 0.34)
const COLOUR_BONUS := Color(0.55, 0.40, 0.60)


## A static box. [param at] is its centre and [param size] its extent, both in units.
static func box(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	colour: Color = COLOUR_FLOOR,
	basis: Basis = Basis.IDENTITY
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(basis, G2GUnits.vector_to_metres(at))

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = G2GUnits.vector_to_metres(size)
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box_shape.size
	mesh.mesh = box_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	mesh.material_override = material

	body.add_child(mesh)
	parent.add_child(body)

	return body


## A ramp: a slab tilted [param angle_degrees] about [param axis].
static func ramp(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	angle_degrees: float,
	axis: Vector3 = Vector3.FORWARD,
	colour: Color = COLOUR_RAMP
) -> StaticBody3D:
	return box(
		parent, at, size, colour, Basis(axis.normalized(), deg_to_rad(angle_degrees))
	)


static func sun(parent: Node3D) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	light.shadow_enabled = true
	parent.add_child(light)

	# A world environment with ambient light, so the shaded stock characters are not
	# black on the side away from the sun.
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.55, 0.65, 0.80)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	environment.ambient_light_energy = 0.8
	env.environment = environment
	parent.add_child(env)

	return light
