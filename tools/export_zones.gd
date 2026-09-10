extends SceneTree

## Writes each built-in map's zones out as the JSON file a delivered map would ship.
## Run after changing a map; the headless suite checks the files still match.
##
## [codeblock]
## godot --headless --path . --script tools/export_zones.gd
## [/codeblock]

func _init() -> void:
	var failures := 0
	# Every hand-written map on disk, not a list. This file carried the third copy of
	# the three map ids -- after G2GGame and the export scripts -- and a map added
	# without editing it got no zones file, which the suite then reported as the map
	# disagreeing with its own zones rather than as never having been exported.
	var ids := _map_ids()
	if ids.is_empty():
		printerr("no maps found in res://maps")
		quit(1)
		return
	for id in ids:
		var script: GDScript = load("res://maps/%s.gd" % id)
		var zones: DotTimerZoneSet = script.build_zones()
		var path := "res://maps/%s.zones.json" % id
		var wrote := zones.save_json(path)
		if wrote.ok:
			print("wrote %s (%d zones, %s)" % [path, zones.zones.size(), zones.fingerprint()])
		else:
			printerr("could not write %s: %s" % [path, wrote.error.message])
			failures += 1
		for problem in zones.problems():
			printerr("  PROBLEM %s: %s" % [id, problem])
			failures += 1
	print("%d map%s exported" % [ids.size(), "" if ids.size() == 1 else "s"])
	quit(1 if failures > 0 else 0)


## The hand-written maps: a `<id>.tscn` in res://maps with a `<id>.gd` beside it.
##
## Imported maps are deliberately skipped -- their zones come out of the .bsp and are
## written by tools/bsp_import.py, so re-exporting one here would overwrite a manifest
## with a zones file of a different shape.
func _map_ids() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open("res://maps")
	if dir == null:
		return out
	for file in dir.get_files():
		if not file.ends_with(".tscn"):
			continue
		var id := file.substr(0, file.length() - 5)
		if ResourceLoader.exists("res://maps/%s.gd" % id):
			out.append(id)
	out.sort()
	return out
