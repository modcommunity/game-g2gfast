extends SceneTree

## Writes each built-in map's zones out as the JSON file a delivered map would ship.
## Run after changing a map; the headless suite checks the files still match.
##
## [codeblock]
## godot --headless --path . --script tools/export_zones.gd
## [/codeblock]

func _init() -> void:
	var failures := 0
	for id in ["bhop_g2g_intro", "surf_g2g_intro"]:
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
	quit(1 if failures > 0 else 0)
