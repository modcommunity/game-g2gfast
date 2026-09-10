extends Node3D

## Renders an imported map to PNGs and exits. `tools/bsp_preview.sh <id> <out.png>`.
##
## An imported map is the one thing in this repository whose bugs are invisible to
## every assertion available: the vertex count can be right, the manifest can be
## right, every material can be correctly configured, and the map can still be
## inside-out, unlit or 200 times too big. This file's own lesson, four times over.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if args.size() > 0 else "surf_kitsune"
	var out := args[1] if args.size() > 1 else "user://bsp_preview.png"
	var shots := int(args[2]) if args.size() > 2 else 4

	# Through the catalogue, like everything else -- an imported map has no scene of
	# its own any more, so resolving one by path only works for the hand-written ones.
	var catalogue := G2GMapCatalogue.discover()
	var def := catalogue.get_map(StringName(id))
	if def == null:
		push_error("no map '%s'. Known: %s" % [id, ", ".join(
			catalogue.maps.map(func(m: DotMapDef) -> String: return String(m.id)))])
		get_tree().quit(1)
		return
	var packed: PackedScene = load(def.scene_path)
	if packed == null:
		push_error("no scene for %s at %s" % [id, def.scene_path])
		get_tree().quit(1)
		return
	var map: Node3D = packed.instantiate()
	if map is G2GBspMap:
		(map as G2GBspMap).build_from(def)
	# Set before add_child: _build() runs from _ready(), so an override applied
	# afterwards is applied to materials that already exist.
	if args.size() > 4 and map is G2GBspMap:
		(map as G2GBspMap).ambient = float(args[4])
	if args.size() > 5 and map is G2GBspMap:
		(map as G2GBspMap).light_boost = float(args[5])
	add_child(map)
	await get_tree().process_frame

	# `lm` overrides every material to show the baked lighting alone. A map whose
	# albedo is black -- kitsune's is, over 5892 triangles of `tools/toolsblack` --
	# renders identically whether the lightmap works or is never sampled at all, so
	# there is no camera angle that answers the question. This one does.
	if args.size() > 6 and args[6] == "lm":
		for mi: MeshInstance3D in _meshes(map):
			for i in range(mi.get_surface_override_material_count()):
				var m := mi.get_surface_override_material(i) as ShaderMaterial
				if m == null:
					continue
				m.set_shader_parameter("has_albedo", false)
				m.set_shader_parameter("tint", Color.WHITE)
				m.set_shader_parameter("ambient", 0.0)
				m.set_shader_parameter("light_boost", 1.0)

	var aabb := _world_aabb(map)
	print("[preview] %s aabb pos=%s size=%s m" % [id, aabb.position, aabb.size])

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.09)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.30, 0.32, 0.38)
	e.ambient_light_energy = 0.5
	env.environment = e
	add_child(env)

	var cam := Camera3D.new()
	cam.far = 6000.0
	add_child(cam)

	# From the spawn, turning on the spot. An orbit of a 600 m map at 1600x900 is
	# three pixels per ramp and cannot tell "unlit" from "small", which is the whole
	# question an imported map raises.
	var from_spawn := args.size() > 3 and args[3] == "spawn"
	var c := aabb.get_center()
	var r: float = maxf(aabb.size.length() * 0.55, 1.0)
	var eye := c
	if from_spawn and map is G2GMap:
		eye = (map as G2GMap).spawn_for(0) + Vector3(0.0, 1.2, 0.0)
	for i in range(shots):
		var a := TAU * float(i) / float(shots) + 0.6
		if from_spawn:
			cam.global_position = eye
			cam.rotation = Vector3(-0.15, a, 0.0)
		else:
			cam.global_position = c + Vector3(cos(a) * r, r * 0.42, sin(a) * r)
			cam.look_at(c, Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(out.replace(".png", "_%d.png" % i))
		print("[preview] wrote ", out.replace(".png", "_%d.png" % i))
	get_tree().quit()


func _world_aabb(root: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in _meshes(root):
		var b := mi.global_transform * mi.get_aabb()
		if first:
			box = b; first = false
		else:
			box = box.merge(b)
	return box


func _meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
