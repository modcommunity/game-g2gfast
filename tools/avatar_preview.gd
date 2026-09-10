extends Node3D

## Renders avatar parts side by side and exits.
##
## `godot --path . tools/avatar_preview.tscn -- <out.png> [count]`
##
## An avatar is the other thing in this repository whose bugs are invisible to
## assertions: every part scene can load, carry the right meshes and report the right
## transform while standing as a pile of limbs at the origin. Only a frame shows it.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "/tmp/avatars.png"
	var count := int(args[1]) if args.size() > 1 else 6

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.14, 0.18)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.76, 0.80)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -40.0, 0.0)
	add_child(sun)

	var letters := "abcdefghijklmnopqr"
	var shown := 0
	for i in range(min(count, letters.length())):
		var letter := letters[i]
		var holder := Node3D.new()
		holder.position = Vector3(float(i) * 1.1 - float(count - 1) * 0.55, 0.0, 0.0)
		add_child(holder)
		# At the rig's own mount heights, not at the origin. A part is authored centred
		# on its slot, so previewing them stacked at 0 draws a head inside a torso and
		# says nothing about whether the character stands up correctly.
		var hull := G2GUnits.to_metres(G2GUnits.PLAYER_HEIGHT)
		var eye := G2GUnits.to_metres(G2GUnits.PLAYER_EYE_HEIGHT)
		for pair in [["body", hull * 0.42], ["head", eye]]:
			var path := "res://avatars/%s_kenney_%s.tscn" % [pair[0], letter]
			if not ResourceLoader.exists(path):
				push_error("missing %s" % path)
				continue
			var part: Node3D = (load(path) as PackedScene).instantiate()
			part.position = Vector3(0.0, float(pair[1]), 0.0)
			holder.add_child(part)

		# The hull the character has to fit, drawn as a wireframe box, because "is this
		# the right size" is the question and an eyeball on a character alone cannot
		# answer it.
		var hull_box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(G2GUnits.to_metres(G2GUnits.PLAYER_HALF_WIDTH * 2.0), hull,
			G2GUnits.to_metres(G2GUnits.PLAYER_HALF_WIDTH * 2.0))
		hull_box.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.4, 0.9, 1.0, 0.13)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hull_box.material_override = m
		hull_box.position = Vector3(0.0, hull * 0.5, 0.0)
		holder.add_child(hull_box)
		shown += 1

	await get_tree().process_frame
	var box := AABB()
	var first := true
	for mi in _meshes(self):
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	print("[avatars] %d shown, bounds pos=%s size=%s" % [shown, box.position, box.size])

	var cam := Camera3D.new()
	add_child(cam)
	var c := box.get_center()
	cam.global_position = c + Vector3(0.0, box.size.y * 0.15, maxf(box.size.x, 1.0) * 1.15)
	cam.look_at(c, Vector3.UP)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[avatars] wrote ", out)
	get_tree().quit()


func _meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
