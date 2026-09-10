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

## The manifest this map builds from. Set by [method build_from]; only an editor
## placement of this scene ever sets it by hand.
@export_file("*.json") var manifest_path: String = ""

## Lifts the baked darks so geometry stays readable. See the shader.
@export_range(0.0, 1.0) var ambient: float = 0.10
@export_range(0.0, 4.0) var light_boost: float = 1.35

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
	fallback_spawn_units = _vec(spawn.get("origin", [0, 64, 0])) + Vector3(0.0, 8.0, 0.0)

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

	# One concave shape for the whole world. A surf map is static geometry and a
	# trimesh is exactly what dot-fps-controller's sweeps want to test against.
	mi.create_trimesh_collision()

	G2GGeometry.sun(self)
	print("[bsp] %s: %d surfaces, %d verts, %d materials" % [
		manifest.get("id", "?"), mesh.get_surface_count(),
		mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0, written])


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
	mat.shader = load("res://game/g2g_bsp_lightmapped.gdshader")
	mat.set_shader_parameter("lightmap_tex", lightmap)
	mat.set_shader_parameter("ambient", ambient)
	mat.set_shader_parameter("light_boost", light_boost)

	var texture_name := str(s.get("texture", ""))
	if not texture_name.is_empty():
		var tex := _load_texture(dir.path_join("textures").path_join(texture_name))
		if tex != null:
			mat.set_shader_parameter("albedo_tex", tex)
			mat.set_shader_parameter("has_albedo", true)
			mat.set_shader_parameter("tint", Color.WHITE)
			return mat

	# No texture: it lived in the game's own VPKs and was never in this file. Paint it
	# with the g2gfast role colour, which is what an untextured surface here means.
	mat.set_shader_parameter("has_albedo", false)
	mat.set_shader_parameter("tint", G2GTextures.ROLE_COLOURS.get(
		_role(str(s.get("role", "FLOOR"))), Color(0.42, 0.44, 0.48)))
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


## Zones: the spawn, and every volume that catches a player who fell off the ride.
##
## START and END are deliberately absent -- see `classify_zones` in the importer.
## A `trigger_teleport` in a surf map is the pit, and dot-timer's RESPAWN is what it is.
func timer_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = StringName(str(manifest.get("id", "imported")))
	zones.meta["tier"] = tier
	zones.meta["source"] = manifest.get("source", "")
	zones.meta["imported"] = true

	var spawn: Dictionary = manifest.get("spawn", {})
	var at := _vec(spawn.get("origin", [0, 64, 0])) + Vector3(0.0, 8.0, 0.0)
	zones.add(zone_spawn(0, at, float(spawn.get("yaw", 0.0))))

	for v: Variant in manifest.get("respawn_volumes", []):
		var vol: Dictionary = v
		zones.add(zone_box(DotTimerZone.Kind.RESPAWN, 0, _vec(vol.get("min")), _vec(vol.get("max"))))
	return zones
