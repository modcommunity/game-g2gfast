extends RefCounted

const G2GTextures := preload("g2g_textures.gd")
const G2GUnits := preload("g2g_units.gd")

## Prototype-textured collision geometry in code, in genre units.
##
## [b]Every argument is in genre units[/b] and converted here, so a map file reads
## like a brush list: a 64-unit-tall block is [code]64[/code], not
## [code]1.2192[/code]. A surf ramp built as "128 wide at 60°" is a ramp a mapper
## who has built one before can read.
##
## Deliberately duplicated from game-playground rather than shared: the family rule
## is that games copy what they need, because a shared helper is a dependency and
## these two games will diverge.

# THESE ARE ROLES NOW, not colours, and they keep the old names because every map in
# this repository and any anybody else has written passes one of them to `box()`.
#
# The change is what happens to them: they used to become a flat `albedo_color` and
# they now select a prototype-textured material through `G2GTextures`. A map file did
# not change and does not have to — which is the point of having had one seam for this
# rather than a colour per box. A map that really wants a flat colour still passes a
# `Color`; `box()` takes either.
const COLOUR_FLOOR := G2GTextures.Role.FLOOR
const COLOUR_RAMP := G2GTextures.Role.RAMP
const COLOUR_START := G2GTextures.Role.START
const COLOUR_END := G2GTextures.Role.END
const COLOUR_PLATFORM := G2GTextures.Role.PLATFORM
const COLOUR_BONUS := G2GTextures.Role.BONUS

## The same six, under the names a new map should be written against.
const ROLE_FLOOR := G2GTextures.Role.FLOOR
const ROLE_RAMP := G2GTextures.Role.RAMP
const ROLE_START := G2GTextures.Role.START
const ROLE_END := G2GTextures.Role.END
const ROLE_PLATFORM := G2GTextures.Role.PLATFORM
const ROLE_BONUS := G2GTextures.Role.BONUS


## A static box. [param at] is its centre and [param size] its extent, both in units.
static func box(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	surface: Variant = ROLE_FLOOR,
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

	mesh.material_override = material_for(surface)

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
	surface: Variant = ROLE_RAMP
) -> StaticBody3D:
	return box(
		parent, at, size, surface, Basis(axis.normalized(), deg_to_rad(angle_degrees))
	)


## The material for a surface, which is either a [enum G2GTextures.Role] or a [Color].
##
## [b]Both, because the roles were `Color` constants until the maps got textures.[/b]
## Every map file in this repository passes `G2GGeometry.COLOUR_*` and so does any map
## anybody wrote against the old signature; those constants are role ids now and go
## down the first branch. A `Color` still means what it always did — a flat, untextured
## surface — which is what a trigger volume or a skybox brush wants, and is the only
## thing that made this worth accepting two types for.
static func material_for(surface: Variant) -> StandardMaterial3D:
	if surface is Color:
		var flat := StandardMaterial3D.new()
		flat.albedo_color = surface
		flat.roughness = 0.92
		flat.metallic = 0.0
		return flat

	return G2GTextures.material_for(surface as G2GTextures.Role)


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
