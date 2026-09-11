class_name G2GTextures
extends RefCounted

## Prototype ("dev") textures for the maps, and where a real texture set is dropped in.
##
## [b]Why a map needs a texture at all, when the geometry is the gameplay.[/b] It is
## not decoration in this genre. A surf ramp is a plane a player rides at 30 m/s and a
## bhop block is one they clear in eight ticks, and both of those are judged entirely
## by [i]how fast the surface is going past[/i] — the only cue for that is a repeating
## pattern with a known size. `G2GGeometry` shipped flat `StandardMaterial3D`
## albedo colours, so every surface in both maps was one unbroken tone: a ramp gave a
## player no way to see their own speed, and a screenshot of the map was a green plane
## with tan boxes on it.
##
## [b]Triplanar, always.[/b] A [BoxMesh] UV-maps every face to the same 0..1 square, so
## without triplanar mapping a 2-metre block and a 40-metre ramp show the same number
## of squares and the texture stops carrying scale — which is its whole job here. The
## grid is therefore sized in WORLD space, and one square is a fixed number of the
## genre's units on every surface in the game.
##
## Deliberately duplicated from `ArenaMap.dev_texture` rather than shared: the family
## rule is that only dot-core is ever a hard dependency, and these two games' texturing
## has already diverged — this one is keyed by role and looks for an external set.

## Where a real texture set is looked for, if one has been installed.
##
## [b]The Kenney prototype kit is what this is for.[/b] It is CC0, which is strictly
## more permissive than the MIT this repository ships under, and its prototype textures
## are the same thing surf and bhop maps have been built in for twenty years. Drop the
## PNGs in at the names in [constant ROLE_FILES] and every map in the game picks them
## up with no change to any map file — the roles below are the whole interface.
##
## Nothing is vendored here and nothing fails without it: a missing directory falls
## back to the generated grid, which is a legitimate look rather than an error state.
## `dot-server-deploy/setup.sh` copies this directory into its own build, so
## anything put here ships in the browser export as well.
const TEXTURE_DIR := "res://textures/prototype"

## What each surface in a map is FOR, which is what decides how it is textured.
##
## [b]A role, not a colour.[/b] The maps used to pass a `Color` per box, so replacing
## the look meant editing every map. A role survives the swap: "this is a surf ramp"
## is true whether it is drawn as a tinted grid or as a Kenney panel.
enum Role {
	## Ordinary floor and walls.
	FLOOR,
	## A surface meant to be ridden — a surf ramp.
	RAMP,
	## Inside the start zone.
	START,
	## Inside the finish zone.
	END,
	## A block a player jumps between.
	PLATFORM,
	## Anything on a bonus track, so a bonus route is visibly not the main one.
	BONUS,
}

## The base colour each role is tinted with. The generated grid is greyscale and is
## multiplied by these, so a texture set installed later is tinted the same way.
const ROLE_COLOURS := {
	Role.FLOOR: Color(0.42, 0.44, 0.48),
	Role.RAMP: Color(0.34, 0.52, 0.66),
	Role.START: Color(0.30, 0.62, 0.36),
	Role.END: Color(0.70, 0.32, 0.32),
	Role.PLATFORM: Color(0.54, 0.50, 0.42),
	Role.BONUS: Color(0.62, 0.46, 0.68),
}

## The file each role loads from [constant TEXTURE_DIR], when one is installed.
const ROLE_FILES := {
	Role.FLOOR: "floor.png",
	Role.RAMP: "ramp.png",
	Role.START: "start.png",
	Role.END: "end.png",
	Role.PLATFORM: "platform.png",
	Role.BONUS: "bonus.png",
}

## How many of the genre's units one grid square covers.
##
## [b]64, because that is the grid this genre's maps are built on.[/b] Every bhop block
## in every map anybody has played is a multiple of 64 units, so a square that is 64
## units across lines its edges up with the geometry instead of cutting across it — and
## a player counting squares along a ramp is counting the same numbers the mapper used.
const UNITS_PER_SQUARE := 64.0

## How many squares are in one generated tile. Larger is a bigger texture for the
## same density; four keeps it to 512 px, which is nothing on any target here.
const SQUARES_PER_TILE := 4

## Pixels per square in the generated tile.
const PIXELS_PER_SQUARE := 128

## Materials already built, by role. Built once and shared by every surface with that
## role in every map — a map is a few hundred boxes and a material per box would be a
## few hundred shader compilations for one texture.
static var _materials: Dictionary = {}

## The one generated tile, shared by every role and tinted per role. Greyscale, so the
## tint is a multiply rather than a second image.
static var _grid: ImageTexture = null


## The material for a role. Cached; call it per box.
static func material_for(role: Role) -> StandardMaterial3D:
	if _materials.has(role):
		return _materials[role]

	var material := StandardMaterial3D.new()
	material.albedo_texture = _texture_for(role)
	material.albedo_color = ROLE_COLOURS.get(role, Color.WHITE)

	# World-space triplanar. `uv1_world_triplanar` is what makes the scale below a
	# size in the WORLD rather than a multiple of each mesh's own UVs — without it a
	# 2-metre block and a 40-metre ramp are textured identically, which is the thing
	# the texture exists to prevent.
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true

	# One tile covers SQUARES_PER_TILE squares, and uv1_scale is in tiles per metre.
	var metres_per_tile := G2GUnits.to_metres(UNITS_PER_SQUARE * float(SQUARES_PER_TILE))
	var scale := 1.0 / maxf(metres_per_tile, 0.001)
	material.uv1_scale = Vector3(scale, scale, scale)

	material.roughness = 0.92
	material.metallic = 0.0

	# Nearest-neighbour, which is a decision rather than a default. A prototype grid is
	# meant to be read as discrete squares at speed; filtered, the lines blur out at
	# exactly the distance and the velocity a player is judging a ramp from, which is
	# the one place they are needed.
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS

	_materials[role] = material

	return material


## The texture a role draws with: an installed one, or the generated grid.
static func _texture_for(role: Role) -> Texture2D:
	var path := "%s/%s" % [TEXTURE_DIR, ROLE_FILES.get(role, "floor.png")]

	# ResourceLoader.exists rather than FileAccess.file_exists: an imported texture in
	# an exported build is a `.ctex` beside a `.png` that is not shipped, so asking the
	# filesystem for the source file answers "no" in exactly the build that matters.
	if ResourceLoader.exists(path, "Texture2D"):
		var loaded: Resource = ResourceLoader.load(path, "Texture2D")

		if loaded is Texture2D:
			return loaded as Texture2D

	return grid_texture()


## The generated prototype grid: greyscale squares with a darker line every square and
## a lighter one at every [constant SQUARES_PER_TILE], so both the small grid and the
## tile boundary are readable.
##
## Greyscale on purpose — every role multiplies it by its own colour, so there is one
## image in memory rather than six.
static func grid_texture() -> ImageTexture:
	if _grid != null:
		return _grid

	var size := PIXELS_PER_SQUARE * SQUARES_PER_TILE
	var image := Image.create(size, size, true, Image.FORMAT_RGB8)

	var base := Color(0.86, 0.86, 0.86)
	var line := Color(0.60, 0.60, 0.60)
	var major := Color(0.40, 0.40, 0.40)

	image.fill(base)

	for x in range(size):
		for y in range(size):
			var on_minor := x % PIXELS_PER_SQUARE < 3 or y % PIXELS_PER_SQUARE < 3
			var on_major := x < 5 or y < 5

			if on_major:
				image.set_pixel(x, y, major)
			elif on_minor:
				image.set_pixel(x, y, line)
			elif (x / PIXELS_PER_SQUARE + y / PIXELS_PER_SQUARE) % 2 == 0:
				# A checker under the grid, at half strength. A pure grid on a ramp
				# seen edge-on collapses to nothing between the lines; the checker is
				# what still carries speed at a glancing angle, which is the angle a
				# surfer spends the whole map at.
				image.set_pixel(x, y, base.darkened(0.07))

	image.generate_mipmaps()

	_grid = ImageTexture.create_from_image(image)

	return _grid


## Whether a texture set is installed, and what it is.
##
## For a `describe()` and for the suite: "the maps are drawn in the generated grid" and
## "the maps are drawn in an installed set" are both correct, and a server operator
## looking at a screenshot cannot tell which they are looking at.
static func describe() -> Dictionary:
	var installed := PackedStringArray()

	for role: Role in ROLE_FILES:
		var path := "%s/%s" % [TEXTURE_DIR, ROLE_FILES[role]]
		if ResourceLoader.exists(path, "Texture2D"):
			installed.append(String(ROLE_FILES[role]))

	return {
		"source": "installed" if installed.size() > 0 else "generated",
		"directory": TEXTURE_DIR,
		"installed": installed,
		"units_per_square": UNITS_PER_SQUARE,
		"roles": ROLE_COLOURS.size(),
	}


## Drops every cached material and the generated tile.
##
## Only for a test that installs a texture set and expects the next map to use it —
## the cache is static and therefore outlives a map change, a game change and every
## scene in the process.
static func reset() -> void:
	_materials.clear()
	_grid = null
