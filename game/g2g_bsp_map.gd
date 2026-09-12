class_name G2GBspMap
extends G2GMap

## A map imported from a Source .bsp, built at load from a manifest anywhere on disk.
##
## `tools/bsp_import.py` writes a `<id>.json`, a `<id>.bin` and a lightmap atlas; this
## turns them into geometry, materials and timer zones.
##
## [b]There is no scene and no script per map, and that is what makes a map droppable.[/b]
## Every imported map is THIS scene -- one `imported_map.tscn` that ships inside the
## build -- pointed at a different manifest through [member DotMapDef.meta]. The
## alternative, a generated `<id>.gd` and `<id>.tscn` beside the data, cannot work for a
## map that arrives after the export: `res://` is a read-only PCK in a shipped build, so
## a scene that is not in it does not exist, and a script in a mounted dot-cloud pack
## cannot resolve `class_name` anyway -- this family measured that and wrote it down.
##
## So a map is data. It can sit in `res://maps/imported/` in a run from source, in
## `user://maps/` after something downloaded it, or at any absolute path an operator
## configured, and the loading path is identical for all three.
##
## [b]Why the mesh is built here and not imported as a scene.[/b] The baked lighting
## needs [constant Mesh.ARRAY_TEX_UV2] to survive to the shader, and every route
## through an importer reassigns what a second UV set means. Building it costs one
## pass over a [PackedByteArray] and keeps this repository's own convention: maps are
## made in code.

const VERTEX_FLOATS := 10          # position 3, normal 3, uv 2, uv2 2

## Zone kinds by the name the manifest writes, which is [enum DotTimerZone.Kind]'s.
##
## [b]Names on the wire, not numbers.[/b] A manifest is read by a build that may be
## older or newer than the one that wrote it -- `user://maps` outlives an update --
## and a number would silently become a different kind the day anything is inserted
## into that enum. dot-timer keeps the numbering compatible with the community
## timers' for exactly this reason, and a name costs nothing to be safe as well.
const KINDS := {
	"START": DotTimerZone.Kind.START, "END": DotTimerZone.Kind.END,
	"RESPAWN": DotTimerZone.Kind.RESPAWN, "STOP": DotTimerZone.Kind.STOP,
	"SLAY": DotTimerZone.Kind.SLAY, "FREESTYLE": DotTimerZone.Kind.FREESTYLE,
	"SPEED_LIMIT": DotTimerZone.Kind.SPEED_LIMIT, "TELEPORT": DotTimerZone.Kind.TELEPORT,
	"SPAWN": DotTimerZone.Kind.SPAWN, "EASY_BHOP": DotTimerZone.Kind.EASY_BHOP,
	"SLIDE": DotTimerZone.Kind.SLIDE, "AIR_ACCELERATE": DotTimerZone.Kind.AIR_ACCELERATE,
	"STAGE": DotTimerZone.Kind.STAGE, "GRAVITY": DotTimerZone.Kind.GRAVITY,
	"PUSH": DotTimerZone.Kind.PUSH, "NO_JUMP": DotTimerZone.Kind.NO_JUMP,
	"AUTO_HOP": DotTimerZone.Kind.AUTO_HOP, "CHECKPOINT": DotTimerZone.Kind.CHECKPOINT,
	"CUSTOM": DotTimerZone.Kind.CUSTOM,
}

## The manifest this map builds from. Set by [method build_from]; only an editor
## placement of this scene ever sets it by hand.
@export_file("*.json") var manifest_path: String = ""

## Lifts the baked darks so geometry stays readable. See the shader.
@export_range(0.0, 1.0) var ambient: float = 0.10
@export_range(0.0, 4.0) var light_boost: float = 1.35

## The same, for a surface drawn in the prototype set rather than in the map's own
## texture.
##
## [b]Higher, because a prototype tile has no darks of its own to lose.[/b] A texture the
## map carried is already a picture, so the baked lightmap only has to shade it. A
## prototype tile is one flat colour and a grid, and the dark one is #333 before the
## lightmap touches it -- in the parts of a surf map the compiler tone-mapped to black
## it comes out black, and the grid a player is reading their speed off goes with it.
##
## [b]0.32, chosen by rendering it.[/b] Three values were put through the client and
## looked at: at 0.0 the start room of surf_year3000 loses the grid on its floor and the
## ramps go from orange to brown; at 0.55 the difference from 0.32 is not visible,
## because by then the lightmap dominates everywhere it is not already black. So this
## is the amount that lifts the crushed darks and stops, which is the same job
## [member ambient] does and the same reason.
@export_range(0.0, 1.0) var prototype_ambient: float = 0.32

var manifest: Dictionary = {}
var _bounds_min := Vector3.ZERO
var _bounds_max := Vector3.ZERO
var _built := false


## Nothing is built on entering the tree.
##
## [DotMapSession] instantiates a map scene and adds it in one call, with no hook in
## between, so a node that built itself in `_ready()` would have to know which map it
## is before anybody could tell it. The host calls [method build_from] instead, from
## `changed`, which carries both the [DotMapDef] and the node -- and does so before it
## asks for [method timer_zones], which is the ordering this depends on.
func _build() -> void:
	if not manifest_path.is_empty():
		# An editor placement, or a preview: it was told a manifest up front.
		build_from_path(manifest_path)


## Build this map from the manifest named by a catalogue entry.
func build_from(map: DotMapDef) -> bool:
	if map == null:
		return false
	var path := str(map.meta.get("manifest", ""))
	if path.is_empty():
		push_error("G2GBspMap: %s has no manifest in its catalogue entry" % String(map.id))
		return false
	return build_from_path(path)


## Build this map from a manifest at any path: `res://`, `user://` or absolute.
func build_from_path(path: String) -> bool:
	if _built:
		return true
	manifest_path = path
	_built = true
	_construct()
	return not manifest.is_empty()


func _construct() -> void:
	if manifest_path.is_empty():
		push_error("G2GBspMap: no manifest_path")
		return
	var text := FileAccess.get_file_as_string(manifest_path)
	if text.is_empty():
		push_error("G2GBspMap: cannot read %s" % manifest_path)
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("G2GBspMap: %s is not a manifest" % manifest_path)
		return
	manifest = parsed

	var dir := manifest_path.get_base_dir()
	tier = int(manifest.get("tier", 3))

	var bounds: Dictionary = manifest.get("bounds", {})
	_bounds_min = _vec(bounds.get("min", [0, 0, 0]))
	_bounds_max = _vec(bounds.get("max", [0, 0, 0]))

	var spawn: Dictionary = manifest.get("spawn", {})
	# No lift added here: the manifest's destinations already carry one, applied at
	# the same boundary the axis swap is. Two lifts is a player dropped from waist
	# height onto every spawn, which reads as the map being badly made.
	fallback_spawn_units = _vec(spawn.get("origin", [0, 64, 0]))

	var lm_info: Dictionary = manifest.get("lightmap", {})
	var lightmap: Texture2D = _load_texture(dir.path_join(str(lm_info.get("file", ""))))

	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % manifest.get("id", "")))
	if blob.is_empty():
		push_error("G2GBspMap: the mesh binary is missing or empty")
		return

	var mesh := ArrayMesh.new()
	var surfaces: Array = manifest.get("surfaces", [])
	for i in range(surfaces.size()):
		var s: Dictionary = surfaces[i]
		var arrays := _surface_arrays(blob, s)
		if arrays.is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_name(mesh.get_surface_count() - 1, str(s.get("material", "?")))

	var mi := MeshInstance3D.new()
	mi.name = "World"
	mi.mesh = mesh
	add_child(mi)

	var written := 0
	for i in range(surfaces.size()):
		if i >= mesh.get_surface_count():
			break
		mi.set_surface_override_material(i, _material_for(surfaces[i], dir, lightmap))
		written += 1

	var solids := _build_collision(mi, blob)

	# [b]The map's own lighting, not this game's.[/b] `G2GGeometry.sun` puts one
	# hardcoded sun at (-55, -35) over a flat blue-grey background, which is right for the
	# hand-built maps it was written for and wrong for every imported one — each of those
	# carries its own sun angle, sun colour, ambient colour, fog range and sky name, and
	# not one of them had ever been read. See [G2GLighting].
	G2GLighting.apply(self, manifest.get("lighting", {}))
	print("[bsp] %s: %d surfaces, %d verts, %d materials, %d collision shapes" % [
		manifest.get("id", "?"), mesh.get_surface_count(),
		mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0,
		written, solids])


## The map's solid volume: one convex shape per brush, plus the displacements.
##
## [b]This is not built from the mesh, and building it from the mesh is the bug it
## replaces.[/b] It was `create_trimesh_collision()` over the drawn geometry, on the
## reasoning that a surf map is static and a trimesh is what a sweep wants. The premise
## is wrong: in a Source map the drawn faces are only the ones that ended up visible,
## and the solid is the brushes. A `nodraw` face is not drawn, a `toolsplayerclip` brush
## -- which is how every surf ramp in the genre is made smooth to ride -- is never drawn
## at all, and across the maps in `inspirations/` between 31% and 77% of the sides of a
## solid brush are one or the other. So the collider was a shell with most of itself
## missing and a player went through the map.
##
## [b]Convex per brush and not one trimesh, now that there is a choice.[/b] A concave
## shape is loose triangles and a sliding hull catches on every interior edge between
## them; on a 45-degree ramp at 3000 u/s that is a run ended by a bump that does not
## exist. A brush is convex by construction, so each one is a single surface with no
## interior edges -- which is the guarantee the genre's own player movement is built on.
## Displacements are the exception, because terrain is not convex: they stay triangles,
## welded across the map at import so at least the seams between them are shared.
##
## Returns how many shapes it made. A manifest with no `collision` block is one written
## before there was one -- `user://maps` is full of those the moment anybody downloads a
## map -- and falls back to the old trimesh, which is wrong in the way described above
## but is still a map somebody can walk around.
func _build_collision(mi: MeshInstance3D, blob: PackedByteArray) -> int:
	var info: Dictionary = manifest.get("collision", {})
	if info.is_empty():
		mi.create_trimesh_collision()
		return 1

	var body := StaticBody3D.new()
	body.name = "Solid"
	add_child(body)

	var made := 0
	var offset := int(info.get("hull_offset", 0))
	for _h in range(int(info.get("hull_count", 0))):
		if offset + 4 > blob.size():
			break
		var count := int(blob.decode_u32(offset))
		offset += 4
		var floats := blob.slice(offset, offset + count * 12).to_float32_array()
		offset += count * 12
		if floats.size() < count * 3:
			break
		var points := PackedVector3Array()
		points.resize(count)
		for v in range(count):
			# Genre units on the wire, metres in the scene -- the one boundary, as ever.
			points[v] = Vector3(floats[v * 3], floats[v * 3 + 1],
				floats[v * 3 + 2]) * G2GUnits.METRES_PER_UNIT
		var hull := ConvexPolygonShape3D.new()
		hull.points = points
		var shape := CollisionShape3D.new()
		shape.shape = hull
		body.add_child(shape)
		made += 1

	var vertex_count := int(info.get("displacement_vertex_count", 0))
	var index_count := int(info.get("displacement_index_count", 0))
	if vertex_count > 0 and index_count > 0:
		var voff := int(info.get("displacement_vertex_offset", 0))
		var coords := blob.slice(voff, voff + vertex_count * 12).to_float32_array()
		var ioff := int(info.get("displacement_index_offset", 0))
		var indices := blob.slice(ioff, ioff + index_count * 4).to_int32_array()
		var faces := PackedVector3Array()
		faces.resize(index_count)
		for i in range(index_count):
			var v := int(indices[i]) * 3
			if v + 2 >= coords.size():
				continue
			faces[i] = Vector3(coords[v], coords[v + 1],
				coords[v + 2]) * G2GUnits.METRES_PER_UNIT
		# `backface_collision` off: a displacement is terrain with a solid brush under
		# it, and a two-sided one catches a player who is already inside the ground
		# instead of letting them out of it.
		var terrain := ConcavePolygonShape3D.new()
		terrain.set_faces(faces)
		var shape := CollisionShape3D.new()
		shape.shape = terrain
		body.add_child(shape)
		made += 1

	return made


func _surface_arrays(blob: PackedByteArray, s: Dictionary) -> Array:
	var vcount := int(s.get("vertex_count", 0))
	var icount := int(s.get("index_count", 0))
	if vcount <= 0 or icount <= 0:
		return []
	var voff := int(s.get("vertex_offset", 0))
	var ioff := int(s.get("index_offset", 0))

	var floats := blob.slice(voff, voff + vcount * VERTEX_FLOATS * 4).to_float32_array()
	var positions := PackedVector3Array(); positions.resize(vcount)
	var normals := PackedVector3Array(); normals.resize(vcount)
	var uvs := PackedVector2Array(); uvs.resize(vcount)
	var uv2s := PackedVector2Array(); uv2s.resize(vcount)
	for v in range(vcount):
		var o := v * VERTEX_FLOATS
		# Genre units on the wire, metres in the scene -- the one boundary, as ever.
		positions[v] = Vector3(floats[o], floats[o + 1], floats[o + 2]) * G2GUnits.METRES_PER_UNIT
		normals[v] = Vector3(floats[o + 3], floats[o + 4], floats[o + 5])
		uvs[v] = Vector2(floats[o + 6], floats[o + 7])
		uv2s[v] = Vector2(floats[o + 8], floats[o + 9])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = blob.slice(ioff, ioff + icount * 4).to_int32_array()
	return arrays


func _material_for(s: Dictionary, dir: String, lightmap: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	# [b]The manifest has carried `translucent` since the importer learned to read a
	# VMT, and nothing had ever read it.[/b] Every surface got the one shader, and that
	# shader wrote ALPHA, so every surface in every imported map was drawn in the
	# transparent pass -- see the comment at the top of it. Opaque is the default and
	# the twenty surfaces the maps actually declare translucent are the exception, which
	# is the way round the .bsp itself says.
	mat.shader = load("res://game/g2g_bsp_translucent.gdshader" if bool(s.get("translucent", false))
		else "res://game/g2g_bsp_lightmapped.gdshader")
	mat.set_shader_parameter("lightmap_tex", lightmap)
	mat.set_shader_parameter("light_boost", light_boost)
	mat.set_shader_parameter("ambient", ambient)

	var texture_name := str(s.get("texture", ""))
	if not texture_name.is_empty():
		var tex := _load_texture(dir.path_join("textures").path_join(texture_name))
		if tex != null:
			mat.set_shader_parameter("albedo_tex", tex)
			mat.set_shader_parameter("has_albedo", true)
			mat.set_shader_parameter("tint", Color.WHITE)
			mat.set_shader_parameter("uv_scale", 1.0)
			return mat

	# No texture the map carried: it lived in the game's own VPKs and was never inside
	# this file, which on a surf map is most of the map -- 97% of surf_beginner2's
	# triangles. This used to be painted a flat role colour and that is what the whole
	# map looked like: one grey mass with the ride invisible in it. It gets the same
	# prototype set the hand-built maps draw in instead, chosen by what the surface is
	# FOR, which the importer worked out from its slope.
	var role := _role(str(s.get("role", "FLOOR")))
	var installed := G2GTextures.installed_texture(role)
	mat.set_shader_parameter("albedo_tex",
		installed if installed != null else G2GTextures.grid_texture())
	mat.set_shader_parameter("has_albedo", true)
	# An installed set carries its own colour per role; the generated grid is greyscale
	# and the role tint is the only thing telling a ramp from a wall in it. Same rule as
	# [method G2GTextures.material_for], and it has to be the same rule, or a surf ramp
	# is one colour in a hand-built map and another in an imported one.
	mat.set_shader_parameter("tint", Color.WHITE if installed != null
		else G2GTextures.ROLE_COLOURS.get(role, Color(0.42, 0.44, 0.48)))
	# The mesh carries UVs in 64-unit grid squares; this is the tile's share of it.
	mat.set_shader_parameter("uv_scale", 1.0 / float(
		G2GTextures.INSTALLED_SQUARES_PER_TILE if installed != null
		else G2GTextures.SQUARES_PER_TILE))
	mat.set_shader_parameter("ambient", prototype_ambient)
	return mat


func _role(name: String) -> G2GTextures.Role:
	match name:
		"RAMP": return G2GTextures.Role.RAMP
		"START": return G2GTextures.Role.START
		"END": return G2GTextures.Role.END
		"PLATFORM": return G2GTextures.Role.PLATFORM
		"BONUS": return G2GTextures.Role.BONUS
		_: return G2GTextures.Role.FLOOR


## A texture, through the resource loader rather than through [method Image.load_from_file].
##
## [b]`Image.load_from_file` on a `res://` path works in a run from source and ships
## nothing.[/b] An export packs the *imported* `.ctex`, not the `.png` the importer
## consumed, so the file the call names is not in the build and every texture in the
## map comes back null — in the browser client, which is the one target that cannot be
## debugged by looking at it. Godot says so in a warning nobody reads. `load()` takes
## the imported resource and is correct in both.
func _load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			return res
	# Outside res://, or not yet imported: this is a development-time path only.
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _vec(a: Variant) -> Vector3:
	var arr: Array = a as Array
	if arr == null or arr.size() < 3:
		return Vector3.ZERO
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


## Zones: everything the manifest worked out about this map.
##
## [b]The importer decides what a zone is; this only reads.[/b] Which volume is the
## finish line is a judgement about a map somebody played, and it is made once --
## in `tools/bsp_import.py` against the entity lump, and in `maps/zones/<id>.json`
## where a map does not label itself. Making it again here would be a second copy of
## the answer, and this family has counted what two copies of one list cost it.
##
## A manifest with no `zones` is one written before there were any: it gets the spawn
## and the pit, which is what it carried and all it can support. `user://maps` is full
## of those the moment anybody downloads a map, and refusing them would take away maps
## that work.
func timer_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = StringName(str(manifest.get("id", "imported")))
	zones.meta["tier"] = tier
	zones.meta["source"] = manifest.get("source", "")
	zones.meta["imported"] = true
	zones.meta["track_names"] = manifest.get("track_names", {})

	var listed: Array = manifest.get("zones", [])
	if listed.is_empty():
		return _legacy_zones(zones)

	for entry: Variant in listed:
		var zone := _zone_from(entry as Dictionary)
		if zone != null:
			zones.add(zone)
	return zones


## One zone from its manifest entry, or null if the kind is not one we know.
##
## An unknown kind is skipped rather than defaulted. [enum DotTimerZone.Kind] starts
## at START, so a `kind` this build has never heard of would otherwise become a second
## start line -- and a track with two of those is a track [DotTimerZoneSet] refuses
## whole, over a zone nobody asked for.
func _zone_from(entry: Dictionary) -> DotTimerZone:
	var name := str(entry.get("kind", ""))
	if not KINDS.has(name):
		DotLog.warn("g2g.maps", "an imported map has a zone kind this build does not know",
			{"map": manifest.get("id", "?"), "kind": name})
		return null

	var kind: DotTimerZone.Kind = KINDS[name]
	var track := int(entry.get("track", DotTimerTrack.MAIN))
	var zone: DotTimerZone

	if entry.has("min") and entry.has("max"):
		zone = zone_box(kind, track, _vec(entry["min"]), _vec(entry["max"]))
	else:
		zone = DotTimerZone.make(kind, track)

	zone.number = float(entry.get("number", 0.0))
	if entry.has("destination"):
		zone.destination = G2GUnits.vector_to_metres(_vec(entry["destination"]))
		zone.destination_yaw = float(entry.get("destination_yaw", 0.0))
	zone.comment = str(entry.get("comment", ""))
	return zone


## The zones a manifest written before `zones` existed can still supply.
func _legacy_zones(zones: DotTimerZoneSet) -> DotTimerZoneSet:
	var spawn: Dictionary = manifest.get("spawn", {})
	zones.add(zone_spawn(DotTimerTrack.MAIN, _vec(spawn.get("origin", [0, 64, 0])),
		float(spawn.get("yaw", 0.0))))

	for v: Variant in manifest.get("respawn_volumes", []):
		var vol: Dictionary = v
		zones.add(zone_box(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN,
			_vec(vol.get("min")), _vec(vol.get("max"))))
	return zones
